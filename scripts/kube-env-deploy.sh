#!/bin/bash
# Remove WORKER related stuff

set -eo pipefail
shopt -s globstar

debug=
function debug_cmd() {
  echo "$> $@"
}

################
# Initial setup
################
usage() {
  echo "Usage: $0 [-n <project-name>] [-r <region>] [-e <production|staging|development>] [-d enable debug or not]" 1>&2
  echo "" 1>&2
  echo "-n defaults to \$CIRCLE_PROJECT_REPONAME, if that is not set, to the basename of the current directory" 1>&2
  echo "-r defaults to \$CLUSTER_REGION_ID, if that is not set, it will default to our main one, hmd" 1>&2
  echo "-e defaults to development" 1>&2
  echo "-d debug mode, disabled by default" 1>&2
  exit 1
}

currentdir="$(dirname "$(readlink -f "$0")")"
kuberootdir="$(readlink -f "$currentdir/../")"
projectdir="${PROJECT_DIR:-$(readlink -f .)}"

# include helper function
. $currentdir/utils/get_first_dir_with_kustomization_file.sh

# initial env vars

ENV=development
# cluster identifier
CLUSTER_REGION_ID=${CLUSTER_REGION_ID:-hmd}
MAIN_GOOGLE_PROJECT_ID="hellomd-181719"
# Project name is the repo name on GitHub or the current folder name if deploying locally
PROJECT_NAME=${CIRCLE_PROJECT_REPONAME:-$(basename $projectdir)}
# Get commit from CircleCI or git sha
COMMIT_SHA1=${CIRCLE_SHA1:-$(git rev-parse HEAD)}
# Are we on CI?
IS_CI=${CIRCLECI:-}

# Docker stuff
IMAGES_TAG=${IMAGES_TAG:-$COMMIT_SHA1}

while getopts ":n:r:e:d" name; do
  case "${name}" in
  n)
    PROJECT_NAME=${OPTARG}
    ;;
  r)
    CLUSTER_REGION_ID=${OPTARG}
    ;;
  e)
    ENV=${OPTARG}
    if ! [[ "$ENV" =~ ^(development|staging|production)$ ]]; then
      usage
    fi
    ;;
  d)
    debug=debug_cmd
    ;;
  *)
    usage
    ;;
  esac
done
shift $((OPTIND - 1))

# Cluster region is a string
CLUSTER_REGION_ID_PATH=$(echo "$CLUSTER_REGION_ID" | awk '{ print tolower($0) }')
CLUSTER_REGION_ID=$(printf '%s\n' "$CLUSTER_REGION_ID" | awk '{ print toupper($0) }' | sed "s/[\.\-]/_/g")

################
# Bastion Setup
################
function gcloud_ssh_bastion() {
  $debug gcloud compute ssh --project "root-networking" --zone "us-west2-a" bastion "$@"
}

# Copy local file to bastion
# gcloud_scp_to_bastion local_file remote_file
function gcloud_scp_to_bastion() {
  echo "Copying local file to Bastion Host: $1 -> $2"
  $debug gcloud compute scp --project "root-networking" --zone "us-west2-a" \
    --recurse $1 bastion:$2
}

# Right now only hmd.za#production is using bastion
SHOULD_USE_BASTION="false"
if [[ $CLUSTER_REGION_ID_PATH == "hmd.za" ]]; then
  SHOULD_USE_BASTION="true"
fi


################
# Development Setup
################
# This is used when running locally to identify the correct gcloud project id and kubernetes context
#  Instead of relying on it being correct on the developer machine
declare -A kubernetes_project_map=( ["HMD"]="hellomd-181719" ["HMD_ZA"]="hellomd-za" ["LOL_LLAMA"]="lol-llama" )
declare -A kubernetes_region_map=( ["HMD"]="us-west1-a" ["HMD-development"]="us-central1-a" ["HMD_ZA"]="europe-west2" ["LOL_LLAMA"]="us-west1-a" )

################
# CI Setup
################
# We only want to run login stuff if running on CIRCLECI
if [[ ! -z "$IS_CI" ]]; then

  missing_required_env=false

  # Those are really long name are not it?
  CLUSTER_REGION_AUTH_VAR="${CLUSTER_REGION_ID}_GOOGLE_AUTH"
  CLUSTER_REGION_PROJECT_ID_VAR="${CLUSTER_REGION_ID}_GOOGLE_PROJECT_ID"
  CLUSTER_REGION_CLUSTER_NAME_VAR="${CLUSTER_REGION_ID}_GOOGLE_CLUSTER_NAME"
  CLUSTER_REGION_COMPUTE_ZONE_VAR="${CLUSTER_REGION_ID}_GOOGLE_COMPUTE_ZONE"

  CLUSTER_REGION_CLUSTER_NAME_VAR_PRODUCTION="${CLUSTER_REGION_CLUSTER_NAME_VAR}_PRODUCTION"
  CLUSTER_REGION_COMPUTE_ZONE_VAR_PRODUCTION="${CLUSTER_REGION_COMPUTE_ZONE_VAR}_PRODUCTION"
  CLUSTER_REGION_CLUSTER_NAME_VAR_STAGING="${CLUSTER_REGION_CLUSTER_NAME_VAR}_STAGING"
  CLUSTER_REGION_COMPUTE_ZONE_VAR_STAGING="${CLUSTER_REGION_COMPUTE_ZONE_VAR}_STAGING"
  CLUSTER_REGION_CLUSTER_NAME_VAR_DEVELOPMENT="${CLUSTER_REGION_CLUSTER_NAME_VAR}_DEVELOPMENT"
  CLUSTER_REGION_COMPUTE_ZONE_VAR_DEVELOPMENT="${CLUSTER_REGION_COMPUTE_ZONE_VAR}_DEVELOPMENT"

  for required_env in \
    $CLUSTER_REGION_AUTH_VAR \
    $CLUSTER_REGION_PROJECT_ID_VAR \
    $CLUSTER_REGION_CLUSTER_NAME_VAR_PRODUCTION \
    $CLUSTER_REGION_COMPUTE_ZONE_VAR_PRODUCTION \
    # Staging disabled temporarily
    # $CLUSTER_REGION_CLUSTER_NAME_VAR_STAGING \
    # $CLUSTER_REGION_COMPUTE_ZONE_VAR_STAGING \
    $CLUSTER_REGION_CLUSTER_NAME_VAR_DEVELOPMENT \
    $CLUSTER_REGION_COMPUTE_ZONE_VAR_DEVELOPMENT; do
    if [ -z "${!required_env}" ]; then
      missing_required_env=true
      echo "$required_env is not set" 1>&2
    fi
  done

  [[ $missing_required_env == "true" ]] && echo "Missing required environment variables, cannot continue" 1>&2 && exit 1

  GOOGLE_AUTH="${!CLUSTER_REGION_AUTH_VAR}"
  GOOGLE_PROJECT_ID="${!CLUSTER_REGION_PROJECT_ID_VAR}"
  GOOGLE_CLUSTER_NAME_PRODUCTION="${!CLUSTER_REGION_CLUSTER_NAME_VAR_PRODUCTION}"
  GOOGLE_COMPUTE_ZONE_PRODUCTION="${!CLUSTER_REGION_COMPUTE_ZONE_VAR_PRODUCTION}"
  GOOGLE_CLUSTER_NAME_STAGING="${!CLUSTER_REGION_CLUSTER_NAME_VAR_STAGING}"
  GOOGLE_COMPUTE_ZONE_STAGING="${!CLUSTER_REGION_COMPUTE_ZONE_VAR_STAGING}"
  GOOGLE_CLUSTER_NAME_DEVELOPMENT="${!CLUSTER_REGION_CLUSTER_NAME_VAR_DEVELOPMENT}"
  GOOGLE_COMPUTE_ZONE_DEVELOPMENT="${!CLUSTER_REGION_COMPUTE_ZONE_VAR_DEVELOPMENT}"

  case "$ENV" in
  "production")
    CLUSTER=$GOOGLE_CLUSTER_NAME_PRODUCTION
    COMPUTE_ZONE=$GOOGLE_COMPUTE_ZONE_PRODUCTION
    ;;
  "staging")
    CLUSTER=$GOOGLE_CLUSTER_NAME_STAGING
    COMPUTE_ZONE=$GOOGLE_COMPUTE_ZONE_STAGING
    ;;
  "development")
    CLUSTER=$GOOGLE_CLUSTER_NAME_DEVELOPMENT
    COMPUTE_ZONE=$GOOGLE_COMPUTE_ZONE_DEVELOPMENT
    ;;
  esac

  echo "Chosen Cluster: $CLUSTER"
  echo "Chosen Compute_Zone: $COMPUTE_ZONE"

  # Configure deployment
  echo $GOOGLE_AUTH | base64 -i --decode >$HOME/gcp-key.json
  gcloud auth activate-service-account --key-file $HOME/gcp-key.json
  gcloud auth configure-docker
  gcloud --quiet config set project $GOOGLE_PROJECT_ID
  gcloud --quiet config set compute/zone $COMPUTE_ZONE
  gcloud --quiet config set container/cluster $CLUSTER
  gcloud --quiet container clusters get-credentials $CLUSTER

  CURRENT_CONTEXT=$(kubectl config current-context)

  # if remote, we also need to configure gcloud there
  if [[ $SHOULD_USE_BASTION == "true" ]]; then
    gcloud_ssh_bastion -- /bin/bash << EOF
      if [[ ! -f ~/gcp-key.json ]]; then
        echo "${GOOGLE_AUTH}" | base64 -i --decode >~/gcp-key.json
        gcloud auth activate-service-account --key-file ~/gcp-key.json
      fi
      gcloud info
      gcloud --quiet container clusters get-credentials \
        --project $GOOGLE_PROJECT_ID \
        --zone $COMPUTE_ZONE \
        $CLUSTER

      kubectl cluster-info --context $CURRENT_CONTEXT
EOF
    echo "Deploying [$PROJECT_NAME] from CircleCI to [$ENV] on [$CURRENT_CONTEXT] via Bastion Host using SSH"
  else
    echo "Deploying [$PROJECT_NAME] from CircleCI to [$ENV] on [$CURRENT_CONTEXT]"
  fi
else
  #  Running locally, so we are getting the values based on the params and the current environment:
  # GOOGLE_PROJECT_ID=${GOOGLE_PROJECT_ID:-$(gcloud config list --format 'value(core.project)' 2>/dev/null)}
  # CURRENT_CONTEXT=$(kubectl config current-context)
  GOOGLE_PROJECT_ID=${GOOGLE_PROJECT_ID:-"${kubernetes_project_map[$CLUSTER_REGION_ID]}"}
  if [[ -n "${kubernetes_region_map[$CLUSTER_REGION_ID-$ENV]}" ]]; then
    COMPUTE_ZONE="${kubernetes_region_map[$CLUSTER_REGION_ID-$ENV]}"
  else
    COMPUTE_ZONE="${kubernetes_region_map[$CLUSTER_REGION_ID]}"
  fi
  CLUSTER="cluster-${ENV}"

  CURRENT_CONTEXT="gke_${GOOGLE_PROJECT_ID}_${COMPUTE_ZONE}_${CLUSTER}"

  if [[ $SHOULD_USE_BASTION == "true" ]]; then
    echo "Deploying [$PROJECT_NAME] locally to [$ENV] on [$CURRENT_CONTEXT] via Bastion Host using SSH"
    echo ""
    echo "### NOTE:"
    echo "Make sure you have logged over SSH"
    echo " to the bastion host atleast one time before and "
    echo " logged on your account using \`gcloud auth login\`"
    echo ""
    echo "Loading Bastion..."
    gcloud_ssh_bastion -- /bin/bash << EOF
      gcloud --quiet container clusters get-credentials \
        --project $GOOGLE_PROJECT_ID \
        --zone $COMPUTE_ZONE \
        $CLUSTER
EOF
  else
    gcloud --quiet config set project $GOOGLE_PROJECT_ID
    gcloud --quiet config set compute/zone $COMPUTE_ZONE
    gcloud --quiet config set container/cluster $CLUSTER
    gcloud --quiet container clusters get-credentials $CLUSTER
    echo "Deploying [$PROJECT_NAME] locally to [$ENV] on [$CURRENT_CONTEXT]"
  fi
fi

echo ""

################
# Docker/Kustomization initial stuff
################

GOOGLE_PROJECT_ID_DOCKER=${GOOGLE_PROJECT_ID_DOCKER:-$MAIN_GOOGLE_PROJECT_ID}
OVERWRITE_APP_IMAGE=${OVERWRITE_APP_IMAGE:-"true"}
OVERWRITE_WORKER_IMAGE=${OVERWRITE_WORKER_IMAGE:-"true"}
OVERWRITE_JOBS_IMAGES=${OVERWRITE_JOBS_IMAGES:-"true"}

# Docker images names
APP_IMAGE_NAME_ONLY=$PROJECT_NAME
APP_IMAGE_NAME=us.gcr.io/${GOOGLE_PROJECT_ID_DOCKER}/$APP_IMAGE_NAME_ONLY
APP_IMAGE=${APP_IMAGE_NAME}:${IMAGES_TAG}

WORKER_IMAGE_NAME_ONLY=$PROJECT_NAME-workers
WORKER_IMAGE_NAME=us.gcr.io/${GOOGLE_PROJECT_ID_DOCKER}/$WORKER_IMAGE_NAME_ONLY
WORKER_IMAGE=${WORKER_IMAGE_NAME}:${IMAGES_TAG}

CRONJOBS_DEFAULT_IMAGE=${APP_IMAGE:-"node:10-alpine"}

echo "Setting main docker image to: [$APP_IMAGE]"
echo "Setting workers docker image to: [$WORKER_IMAGE]"

echo "Cluster Region: $CLUSTER_REGION_ID"

echo "currentdir: " $currentdir
echo "kuberootdir: " $kuberootdir
echo "projectdir: " $projectdir

echo ""
printf "debug? "
if [[ -n $debug ]]; then
  printf "yes"
else
  printf "no"
fi

echo ""
echo ""

PROJECT_DOCKERFILE_MAIN=${PROJECT_DOCKERFILE_MAIN:-"$projectdir/Dockerfile"}
PROJECT_DOCKERFILE_WORKER=${PROJECT_DOCKERFILE_WORKER:-"$projectdir/Dockerfile.cron"}

has_main_dockerfile=false
has_worker_dockerfile=false

has_main_deployment=false
has_worker_deployment=false

has_jobs_folder=false

has_main_kustomization=false
has_main_env_kustomization=false
has_main_cluster_kustomization=false
has_main_cluster_env_kustomization=false

# @DEPRECATED - @TODO Remove
has_worker_kustomization=false
has_worker_env_kustomization=false
has_worker_cluster_kustomization=false
has_worker_cluster_env_kustomization=false

has_jobs_kustomization=false
has_jobs_env_kustomization=false
has_jobs_cluster_kustomization=false
has_jobs_cluster_env_kustomization=false

if [[ -f $PROJECT_DOCKERFILE_MAIN ]]; then
  has_main_deployment=true
  has_main_dockerfile=true
fi

if [[ -f $PROJECT_DOCKERFILE_WORKER ]]; then
  has_worker_deployment=true
  has_worker_dockerfile=true
fi

[[ -d "./jobs" && -n $(ls -A ./jobs/*/ 2>/dev/null) ]] && has_jobs_folder=true

if [[ $has_main_dockerfile != true && $has_worker_dockerfile != true ]]; then
  echo "Warning: No Dockerfile or Dockerfile.cron file found, no image will be built"
fi

# Helper function to retrieve dirname for each item on array, modifies passed array
function map_array_items_dirname() {
  local -n arr=$1 # use nameref to change original array
  for i in "${!arr[@]}"; do
    arr[$i]=$(dirname ${arr[$i]})
  done
}

mkdir -p $projectdir/kube

rm -rf $projectdir/kube.out
cp -rf $projectdir/kube $projectdir/kube.out

################
# main kustomization files
################
main_kustomization_file="$projectdir/kube.out/#/main/base/kustomization.yaml"
main_env_kustomization_file="$projectdir/kube.out/#/main/overlays/$ENV/kustomization.yaml"
main_cluster_kustomization_file=$projectdir/kube.out/$CLUSTER_REGION_ID_PATH/main/base/kustomization.yaml
main_cluster_env_kustomization_file=$projectdir/kube.out/$CLUSTER_REGION_ID_PATH/main/overlays/$ENV/kustomization.yaml
main_possible_kustomization_files=(
  "$main_cluster_env_kustomization_file"
  "$main_cluster_kustomization_file"
  "$main_env_kustomization_file"
  "$main_kustomization_file"
)
main_possible_kustomization_folders=("${main_possible_kustomization_files[@]}")
map_array_items_dirname main_possible_kustomization_folders
# general ones
main_possible_general_kustomization_files=(
  "$main_env_kustomization_file"
  "$main_kustomization_file"
)
main_possible_general_kustomization_folders=("${main_possible_general_kustomization_files[@]}")
map_array_items_dirname main_possible_general_kustomization_folders

if [[ -f $main_kustomization_file ]]; then
  has_main_deployment=true
  has_main_kustomization=true
fi
if [[ -f $main_env_kustomization_file ]]; then
  has_main_deployment=true
  has_main_env_kustomization=true
fi
if [[ -f $main_cluster_kustomization_file ]]; then
  has_main_deployment=true
  has_main_cluster_kustomization=true
fi
if [[ -f $main_cluster_env_kustomization_file ]]; then
  has_main_deployment=true
  has_main_cluster_env_kustomization=true
fi

################
# Worker kustomization files (@DEPRECATED - @TODO Remove)
################
worker_kustomization_file="$projectdir/kube.out/#/worker/base/kustomization.yaml"
worker_env_kustomization_file="$projectdir/kube.out/#/worker/overlays/$ENV/kustomization.yaml"
worker_cluster_kustomization_file=$projectdir/kube.out/$CLUSTER_REGION_ID_PATH/worker/base/kustomization.yaml
worker_cluster_env_kustomization_file=$projectdir/kube.out/$CLUSTER_REGION_ID_PATH/worker/overlays/$ENV/kustomization.yaml
worker_possible_kustomization_files=(
  "$worker_cluster_env_kustomization_file"
  "$worker_cluster_kustomization_file"
  "$worker_env_kustomization_file"
  "$worker_kustomization_file"
)
worker_possible_kustomization_folders=("${worker_possible_kustomization_files[@]}")
map_array_items_dirname worker_possible_kustomization_folders
# general ones
worker_possible_general_kustomization_files=(
  "$worker_env_kustomization_file"
  "$worker_kustomization_file"
)
worker_possible_general_kustomization_folders=("${worker_possible_general_kustomization_files[@]}")
map_array_items_dirname worker_possible_general_kustomization_folders

if [[ -f $worker_kustomization_file ]]; then
  has_worker_deployment=true
  has_worker_kustomization=true
fi
if [[ -f $worker_env_kustomization_file ]]; then
  has_worker_deployment=true
  has_worker_env_kustomization=true
fi
if [[ -f $worker_cluster_kustomization_file ]]; then
  has_worker_deployment=true
  has_worker_cluster_kustomization=true
fi
if [[ -f $worker_cluster_env_kustomization_file ]]; then
  has_worker_deployment=true
  has_worker_cluster_env_kustomization=true
fi

################
# Jobs kustomization files
################
jobs_kustomization_file="$projectdir/kube.out/#/jobs/base/kustomization.yaml"
jobs_env_kustomization_file="$projectdir/kube.out/#/jobs/overlays/$ENV/kustomization.yaml"
jobs_cluster_kustomization_file=$projectdir/kube.out/$CLUSTER_REGION_ID_PATH/jobs/base/kustomization.yaml
jobs_cluster_env_kustomization_file=$projectdir/kube.out/$CLUSTER_REGION_ID_PATH/jobs/overlays/$ENV/kustomization.yaml
jobs_possible_kustomization_files=(
  "$jobs_cluster_env_kustomization_file"
  "$jobs_cluster_kustomization_file"
  "$jobs_env_kustomization_file"
  "$jobs_kustomization_file"
)
jobs_possible_kustomization_folders=("${jobs_possible_kustomization_files[@]}")
map_array_items_dirname jobs_possible_kustomization_folders
# general ones
jobs_possible_general_kustomization_files=(
  "$jobs_env_kustomization_file"
  "$jobs_kustomization_file"
)
jobs_possible_general_kustomization_folders=("${jobs_possible_general_kustomization_files[@]}")
map_array_items_dirname jobs_possible_general_kustomization_folders

if [[ -f $jobs_kustomization_file ]]; then
  has_jobs_kustomization=true
fi
if [[ -f $jobs_env_kustomization_file ]]; then
  has_jobs_env_kustomization=true
fi
if [[ -f $jobs_cluster_kustomization_file ]]; then
  has_jobs_cluster_kustomization=true
fi
if [[ -f $jobs_cluster_env_kustomization_file ]]; then
  has_jobs_cluster_env_kustomization=true
fi

################
# Confirm if want to continue (in case not on CI)
################
if [[ -z "$IS_CI" ]]; then
  echo ""
  read -r -p "Are you sure you want to continue? [y/N] " response
  case "$response" in
  [yY][eE][sS] | [yY])
    echo "Continuing..."
    ;;
  *)
    exit 0
    ;;
  esac
fi

echo ""
echo ""

################
# Docker Image Building
################
GCR_TOKEN="$(gcloud config config-helper --format 'value(credential.access_token)')"

if [[ -z ${SKIP_IMAGE_BUILD+x} ]]; then

  if [[ -f "$projectdir/kube.out/#-build-docker-images.sh" ]]; then

    echo "./kube.out/#-build-docker-images.sh script found - Running it"
    $debug "$projectdir/kube.out/#-build-docker-images.sh"

  elif [[ $has_main_dockerfile == "true" || $has_worker_dockerfile == "true" ]]; then

    echo "Preparing to build Dockerfiles"
    echo ""

    if [[ $has_main_dockerfile == "true" ]]; then
      if [[ "$OVERWRITE_APP_IMAGE" == "true" || $(curl -H "Authorization: Bearer $GCR_TOKEN" --fail https://us.gcr.io/v2/$GOOGLE_PROJECT_ID_DOCKER/$APP_IMAGE_NAME_ONLY/manifests/$IMAGES_TAG 2>/dev/null) == "" ]]; then
        [[ "$OVERWRITE_APP_IMAGE" == "true" ]] && echo "Overwriting existing image at \"$APP_IMAGE\" if any"

        if [[ "$(docker images -q prebuilt-main-image 2> /dev/null)" != "" ]]; then
          echo "Prebuilt main image found, just tagging it"
          $debug docker tag prebuilt-main-image $APP_IMAGE
        else
          echo "Starting main Dockerfile build"
          $debug docker build -t $APP_IMAGE .
        fi

        echo "Pushing built main docker image to GCR."
        $debug docker push $APP_IMAGE
      else
        echo "Not building main Dockerfile because an existing image exists at \"$APP_IMAGE\" and OVERWRITE_APP_IMAGE=true was not passed"
      fi
    else
      echo "No main Dockerfile found, skipping..."
    fi

    echo ""

    if [[ $has_worker_dockerfile == "true" ]]; then
      if [[ "$OVERWRITE_WORKER_IMAGE" == "true" || $(curl -H "Authorization: Bearer $GCR_TOKEN" --fail https://us.gcr.io/v2/$GOOGLE_PROJECT_ID_DOCKER/$WORKER_IMAGE_NAME_ONLY/manifests/$IMAGES_TAG 2>/dev/null) == "" ]]; then
        [[ "$OVERWRITE_WORKER_IMAGE" == "true" ]] && echo "Overwriting existing image at \"$WORKER_IMAGE\" if any"

        echo "Starting worker Dockerfile build"
        $debug docker build -t $WORKER_IMAGE -f Dockerfile.cron .

        echo "Pushing built worker docker image to GCR."
        $debug docker push $WORKER_IMAGE
      else
        echo "Not building worker Dockerfile because an existing image exists at \"$WORKER_IMAGE\" and OVERWRITE_WORKER_IMAGE=true was not passed"
      fi
    else
      echo "No worker Dockerfile found, skipping..."
    fi
  fi
else
  echo "SKIP_IMAGE_BUILD was set - Skipping Docker image build"
fi

################
# Specify Default Kustomize files
################
rm -rf $kuberootdir/kube.out
cp -rf $kuberootdir/kube $kuberootdir/kube.out
mkdir -p $kuberootdir/kube.out/manifests/

# .env.yaml file handling
# We cannot simply append the value to the array
# https://github.com/kubernetes/kubernetes/issues/58477
# $1 is the path to the file
function add_env_vars() {
  echo "found .env.yaml file at $1"

  if [ ! -x "$(command -v yq)" ]; then
    echo "yq command not found on path" >&2
    echo "please install it: https://github.com/mikefarah/yq" >&2
    exit 1
  fi

  env_json=$(yq r -j $1)

  echo "getting json from other bases"

  # svc
  svc_file="$kuberootdir/kube.out/#/svc/base/svc-deployment.yaml"
  svc_json=$(yq r -j $svc_file)
  # worker
  worker_file="$kuberootdir/kube.out/#/worker/base/worker-deployment.yaml"
  worker_json=$(yq r -j $worker_file)
  # jbos
  jobs_file="$kuberootdir/kube.out/#/jobs/base/cronjob.yaml"
  jobs_json=$(yq r -j $jobs_file)

  # jq magic follows
  # svc
  echo "adding .env.yaml envs to base svc definitions"
  jq '.[0].spec.template.spec.containers[0].env=(.[1]+.[0].spec.template.spec.containers[0].env | unique_by(.name)) | .[0]' \
    -s <(echo "$svc_json") <(echo "$env_json") | yq r - > $svc_file
  # worker
  echo "adding .env.yaml envs to base worker definitions"
  jq '.[0].spec.template.spec.containers[0].env=(.[1]+.[0].spec.template.spec.containers[0].env | unique_by(.name)) | .[0]' \
    -s <(echo "$worker_json") <(echo "$env_json") | yq r - > $worker_file
  # jobs
  echo "adding .env.yaml envs to base jobs definitions"
  jq '.[0].spec.jobTemplate.spec.template.spec.containers[0].env=(.[1]+.[0].spec.jobTemplate.spec.template.spec.containers[0].env | unique_by(.name)) | .[0]' \
    -s <(echo "$jobs_json") <(echo "$env_json") | yq r - > $jobs_file
}

if [ -f "$projectdir/kube.out/#/.env.yaml" ]; then
  echo ""
  add_env_vars "$projectdir/kube.out/#/.env.yaml"
fi

# Do it again, but this time for the cluster one, if it exists
if [ -f "$projectdir/kube.out/$CLUSTER_REGION_ID_PATH/.env.yaml" ]; then
  echo ""
  add_env_vars "$projectdir/kube.out/$CLUSTER_REGION_ID_PATH/.env.yaml"
fi

kustomize_default_svc_folders=(
  "$kuberootdir/kube.out/$CLUSTER_REGION_ID_PATH/svc/overlays/$ENV/"
  "$kuberootdir/kube.out/$CLUSTER_REGION_ID_PATH/svc/base/"
  "$kuberootdir/kube.out/#/svc/overlays/$ENV/"
  "$kuberootdir/kube.out/#/svc/base/"
)
kustomize_default_jobs_folders=(
  "$kuberootdir/kube.out/$CLUSTER_REGION_ID_PATH/jobs/overlays/$ENV/"
  "$kuberootdir/kube.out/$CLUSTER_REGION_ID_PATH/jobs/base/"
  "$kuberootdir/kube.out/#/jobs/overlays/$ENV/"
  "$kuberootdir/kube.out/#/jobs/base/"
)
kustomize_default_worker_folders=(
  "$kuberootdir/kube.out/$CLUSTER_REGION_ID_PATH/worker/overlays/$ENV/"
  "$kuberootdir/kube.out/$CLUSTER_REGION_ID_PATH/worker/base/"
  "$kuberootdir/kube.out/#/worker/overlays/$ENV/"
  "$kuberootdir/kube.out/#/worker/base/"
)

KUSTOMIZE_DEFAULT_SVC_FOLDER=$(get_first_dir_with_kustomization_file "${kustomize_default_svc_folders[@]}")
KUSTOMIZE_DEFAULT_JOBS_FOLDER=$(get_first_dir_with_kustomization_file "${kustomize_default_jobs_folders[@]}")
KUSTOMIZE_DEFAULT_WORKER_FOLDER=$(get_first_dir_with_kustomization_file "${kustomize_default_worker_folders[@]}")

kustomize_main_project_folder=$(
  get_first_dir_with_kustomization_file "${main_possible_kustomization_folders[@]}" 2>/dev/null || echo $KUSTOMIZE_DEFAULT_SVC_FOLDER
)
kustomize_main_general_project_folder=$(
  get_first_dir_with_kustomization_file "${main_possible_general_kustomization_folders[@]}" 2>/dev/null || echo ""
)

kustomize_jobs_project_folder=$(
  get_first_dir_with_kustomization_file "${jobs_possible_kustomization_folders[@]}" 2>/dev/null || echo $KUSTOMIZE_DEFAULT_JOBS_FOLDER
)
kustomize_jobs_general_project_folder=$(
  get_first_dir_with_kustomization_file "${jobs_possible_general_kustomization_folders[@]}" 2>/dev/null || echo ""
)

kustomize_worker_project_folder=$(
  get_first_dir_with_kustomization_file "${worker_possible_kustomization_folders[@]}" 2>/dev/null || echo $KUSTOMIZE_DEFAULT_WORKER_FOLDER
)
kustomize_worker_general_project_folder=$(
  get_first_dir_with_kustomization_file "${worker_possible_general_kustomization_folders[@]}" 2>/dev/null || echo ""
)

echo ""
echo ""

echo "Choosen Kustomize main folder: " $kustomize_main_project_folder
echo "Choosen Kustomize jobs folder: " $kustomize_jobs_project_folder
echo "Choosen Kustomize worker folder: " $kustomize_worker_project_folder

echo ""

################
# Run envsubst on kustomization.yaml files
################

# Export required vars for subshells
export ENV=$ENV
export CLUSTER_REGION_ID=$CLUSTER_REGION_ID
export CLUSTER_REGION_ID_PATH=$CLUSTER_REGION_ID_PATH
export COMMIT_SHA1=$COMMIT_SHA1
export PROJECT_NAME=$PROJECT_NAME
export IMAGES_TAG=$IMAGES_TAG
export GOOGLE_PROJECT_ID_DOCKER=$GOOGLE_PROJECT_ID_DOCKER
export GCR_TOKEN=$GCR_TOKEN

echo ""
echo ""

# Default files
for filename in $kuberootdir/kube.out/**/*/kustomization.yaml; do
  [ -e "$filename" ] || continue
  # env vars to subst follow below
  $currentdir/replace-envs-on-file.sh -f $filename -o \
    '$ENV'
done

echo ""
echo ""

# Project files
for filename in $projectdir/kube.out/**/*/kustomization.yaml; do
  [ -e "$filename" ] || continue

  base_svc=
  base_jobs=
  base_worker=

  # File is not a general one
  # Identify the general one, if any
  if [[ $filename != "$projectdir/kube.out/#"* ]]; then
    if [[ -n $kustomize_main_general_project_folder ]]; then
      base_svc=$kustomize_main_general_project_folder
    fi
    if [[ -n $kustomize_jobs_general_project_folder ]]; then
      base_jobs=$kustomize_jobs_general_project_folder
    fi
    if [[ -n $kustomize_worker_general_project_folder ]]; then
      base_worker=$kustomize_worker_general_project_folder
    fi
  fi

  export K8S_KUSTOMIZATION_SVC_BASE=$(realpath --relative-to=$(dirname $filename) ${base_svc:-$KUSTOMIZE_DEFAULT_SVC_FOLDER})
  export K8S_KUSTOMIZATION_JOBS_BASE=$(realpath --relative-to=$(dirname $filename) ${base_jobs:-$KUSTOMIZE_DEFAULT_JOBS_FOLDER})
  export K8S_KUSTOMIZATION_WORKER_BASE=$(realpath --relative-to=$(dirname $filename) ${base_worker:-$KUSTOMIZE_DEFAULT_WORKER_FOLDER})

  # env vars to subst follow below
  $currentdir/replace-envs-on-file.sh -f $filename -o \
    '$ENV $CLUSTER_REGION_ID $CLUSTER_REGION_ID_PATH $K8S_KUSTOMIZATION_SVC_BASE $K8S_KUSTOMIZATION_JOBS_BASE $K8S_KUSTOMIZATION_WORKER_BASE'

  echo "Using Base Kustomize main folder: $K8S_KUSTOMIZATION_SVC_BASE ($KUSTOMIZE_DEFAULT_SVC_FOLDER)"
  echo "Using Base Kustomize jobs folder: $K8S_KUSTOMIZATION_JOBS_BASE ($KUSTOMIZE_DEFAULT_JOBS_FOLDER)"
  echo "Using Base Kustomize worker folder: $K8S_KUSTOMIZATION_WORKER_BASE ($KUSTOMIZE_DEFAULT_WORKER_FOLDER)"

  echo ""
done

if [[ $has_main_deployment == "true" ]]; then
  echo "Calling kustomize on $kustomize_main_project_folder and saving output to $kuberootdir/kube.out/manifests/main.yaml"
  kustomize build $kustomize_main_project_folder >$kuberootdir/kube.out/manifests/main.yaml
  IMAGE=$APP_IMAGE $currentdir/replace-envs-on-file.sh -f $kuberootdir/kube.out/manifests/main.yaml -o \
    '$ENV $PROJECT_NAME $COMMIT_SHA1 $IMAGE'
fi

if [[ $has_worker_deployment == "true" ]]; then
  echo "Calling kustomize on $kustomize_worker_project_folder and saving output to $kuberootdir/kube.out/manifests/worker.yaml"
  kustomize build $kustomize_worker_project_folder >$kuberootdir/kube.out/manifests/worker.yaml
  IMAGE=$WORKER_IMAGE $currentdir/replace-envs-on-file.sh -f $kuberootdir/kube.out/manifests/worker.yaml -o \
    '$ENV $PROJECT_NAME $COMMIT_SHA1 $IMAGE'
fi

echo ""
echo ""

################
# Check for Jobs
################

if [[ $has_jobs_folder == "true" ]]; then
  echo "Preparing cronjobs for project [$PROJECT_NAME]"

  args=()
  [[ -n "$debug" ]] && args=("-d")

  $currentdir/create-jobs.sh -j $(readlink -f ./jobs) -i $CRONJOBS_DEFAULT_IMAGE -b $kustomize_jobs_project_folder "${args[@]}"

  echo ""
  
  echo "Done with cronjobs for project [$PROJECT_NAME]"
else
  echo "No cronjobs for project [$PROJECT_NAME]"
fi
  
echo ""
echo ""

##############
# Create Dirs on Bastion If Necessary
##############
if [[ $SHOULD_USE_BASTION == "true" ]]; then
  if [[ $IS_CI == "true" ]]; then
    BASTION_KUBE_DIR="~/kube/manifests/${PROJECT_NAME}/${ENV}/build-${CIRCLE_BUILD_NUM}"
  else
    BASTION_KUBE_DIR="~/kube/manifests/${PROJECT_NAME}/${ENV}"
  fi

  echo "Creating $BASTION_KUBE_DIR/jobs directory tree on Bastion host in case it does not exists."

  # make sure the path exists, we are /jobs because it's the only nested folder that can exist,
  #  and for scp to work all subfolders must exist.
  gcloud_ssh_bastion --command "mkdir -p $BASTION_KUBE_DIR/jobs"

  echo ""
fi

################
# Update Config Maps
################
# Create config map using kubectl locally or on bastion host
# If on bastion host, file will be moved to temp folder and after removed
# create_configmap $name $file_or_dir
function create_configmap() {
  if [[ $SHOULD_USE_BASTION == "true" ]]; then
    full_file_path=$(readlink -f "$2")
    if [[ -f "$full_file_path" ]]; then
      file_basename=$(basename $full_file_path)
      file_dirname=$(dirname $full_file_path)
      tar cf - -C $file_dirname . | gcloud_ssh_bastion -- 'D=`mktemp -d`; tar xf - -C $D; echo $(readlink -f $D); ls -al $D; kubectl create configmap '"$1"' --from-file=$D/'"$file_basename"' --dry-run --save-config -o yaml | kubectl apply -f -'
    elif [[ -d "$full_file_path" ]]; then
      tar cf - -C $full_file_path . | gcloud_ssh_bastion -- 'D=`mktemp -d`; tar xf - -C $D; echo $(readlink -f $D); ls -al $D; kubectl create configmap '"$1"' --from-file=$D --dry-run --save-config -o yaml | kubectl apply -f -'
    else
      echo "Error running create_configmap, $full_file_path is not a file or directory. Bailing out"
      exit 1  
    fi
  else
    kubectl create configmap $1 --from-file=$2 --dry-run --save-config -o yaml | kubectl apply -f -
  fi
}

# Run update-configmap if it exists
if [[ -f "$projectdir/kube.out/#-update-configmaps.sh" ]]; then
  echo "Script to update config maps found - Updating them"
  # It's ran on current context so it inherits the helper functions we defined
  $debug . "$projectdir/kube.out/#-update-configmaps.sh"
else
  echo "Skipping config maps update - no ./kube.out/#-update-configmaps.sh script found"
fi

# quit if we only want to do that
[[ ! -z $UPDATE_CONFIG_ONLY && $UPDATE_CONFIG_ONLY != "false" ]] && echo "UPDATE_CONFIG_ONLY given, stopping now" && exit 0

echo ""

##############
# Kubectl Apply
##############
# General function to apply k8s configs, using or not linkerd
function kubectl_apply() {
  # Linkerd would go here, but we are not using for now
  # Waiting for the following issue to be fixed:
  # https://github.com/linkerd/linkerd2/issues/1595
  # if [[ "$ENV" = "development" && " ${services_with_linkerd[@]} " =~ " ${PROJECT_NAME} " ]] || [[ "$ENV" = "staging" && " ${services_with_linkerd[@]} " =~ " ${PROJECT_NAME} " ]]; then
  #   linkerd version
  #   cat $projectdir/out/kube.yml | linkerd inject --proxy-log-level=linkerd2_proxy::control::destination::background::destination_set=trace,linkerd2_proxy::control::destination::background=trace - | kubectl apply -f -
  # else
  #   kubectl apply -f $projectdir/out/kube.yml
  # fi

  $debug kubectl apply -f $1
}

for filename in $kuberootdir/kube.out/manifests/**/*.yaml; do
  [ -e "$filename" ] || continue

  # if production on hmd.za, use ssh instead
  if [[ $SHOULD_USE_BASTION == "true" ]]; then
    remote_base_filename=${filename#"$kuberootdir/kube.out/manifests/"}
    remote_full_filename=$BASTION_KUBE_DIR/$remote_base_filename

    # first copy manifest file to bastion
    gcloud_scp_to_bastion $filename $remote_full_filename

    echo "Calling kubectl apply -f on remote file $remote_full_filename"

    # then kubectl apply it
    gcloud_ssh_bastion --command "kubectl --context $CURRENT_CONTEXT apply -f $remote_full_filename"

  else
    echo "Calling kubectl apply -f on file $filename"
    $debug kubectl apply -f $filename
  fi
done

if [[ $SHOULD_USE_BASTION == "true" ]]; then

  echo "Removing $BASTION_KUBE_DIR directory on Bastion Host."
  gcloud_ssh_bastion --command "rm -rf $BASTION_KUBE_DIR"
  echo ""

  echo "Removing ssh keys from CircleCI OS-Login profile to not hit 32 KiB profile limit"

  # could also use sed 1d to delete first line
  for i in $(gcloud compute os-login ssh-keys list | tail -n +2); do
    echo $i
    gcloud compute os-login ssh-keys remove --key $i
  done
fi

echo ""
echo ""

echo "Finished deploy 🚀 🚀 🚀"
