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
  echo "Usage: $0 [-e <production|staging|development>] [-n <project-name>] [-r <region>] [-d enable debug or not]" 1>&2
  echo "" 1>&2
  echo "-r defaults to \$CLUSTER_REGION_ID, if that is not set, it will default to our main one, hmd" 1>&2
  echo "-n defaults to \$CIRCLE_PROJECT_REPONAME, if that is not set, to the basename of the current directory" 1>&2
  echo "-e defaults to development" 1>&2
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
# Project name is the repo name on GitHub or the current folder name if deploying locally
PROJECT_NAME=${CIRCLE_PROJECT_REPONAME:-$(basename $projectdir)}
# Get commit from CircleCI or git sha
COMMIT_SHA1=${CIRCLE_SHA1:-$(git rev-parse HEAD)}
# Are we on CI?
IS_CI=${CIRCLECI:-}

# Docker stuff
IMAGES_TAG=${IMAGES_TAG:-$COMMIT_SHA1}

while getopts ":e:n:r:d" name; do
  case "${name}" in
  e)
    ENV=${OPTARG}
    if ! [[ "$ENV" =~ ^(development|staging|production)$ ]]; then
      usage
    fi
    ;;
  n)
    PROJECT_NAME=${OPTARG}
    ;;
  r)
    CLUSTER_REGION_ID=${OPTARG}
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
CLUSTER_REGION_ID=$(printf '%s\n' "$CLUSTER_REGION_ID" | awk '{ print toupper($0) }' | sed "s/\./_/g")

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

################
# CI Setup
################
# We only want to run login stuff if running on CIRCLECI
if [[ ! -z "$IS_CI" ]]; then

  missing_required_env=false

  # Those are really long name are not it?
  CLUSTER_REGION_AUTH_VAR="${CLUSTER_REGION_ID}_GOOGLE_AUTH"
  CLUSTER_REGION_PROJECT_ID_VAR="${CLUSTER_REGION_ID}_GOOGLE_PROJECT_ID"
  CLUSTER_REGION_CLUSTER_NAME_VAR="${CLUSTER_REGION_ID}_GOOGLE_DEVELOPMENT_CLUSTER_NAME"
  CLUSTER_REGION_COMPUTE_ZONE_VAR="${CLUSTER_REGION_ID}_GOOGLE_DEVELOPMENT_COMPUTE_ZONE"

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
    $CLUSTER_REGION_CLUSTER_NAME_VAR_STAGING \
    $CLUSTER_REGION_COMPUTE_ZONE_VAR_STAGING \
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
  echo "Deploying [$PROJECT_NAME] from CircleCI to [$ENV] on [$CURRENT_CONTEXT]"
else
  # Running locally, so we expect this to be correct
  GOOGLE_PROJECT_ID=${GOOGLE_PROJECT_ID:-$(gcloud config list --format 'value(core.project)' 2>/dev/null)}
  CURRENT_CONTEXT=$(kubectl config current-context)
  echo "Deploying [$PROJECT_NAME] locally to [$ENV] on [$CURRENT_CONTEXT]"
fi

################
# Docker/Kustomization initial stuff
################

# Docker images names
APP_IMAGE_NAME=us.gcr.io/${GOOGLE_PROJECT_ID}/$PROJECT_NAME
APP_IMAGE=${APP_IMAGE_NAME}:${IMAGES_TAG}

WORKER_IMAGE_NAME=us.gcr.io/${GOOGLE_PROJECT_ID}/$PROJECT_NAME-workers
WORKER_IMAGE=${WORKER_IMAGE_NAME}:${IMAGES_TAG}

CRONJOBS_DEFAULT_IMAGE=${APP_IMAGE:-"node:10-alpine"}

echo "Setting main docker image to: [$APP_IMAGE]"
echo "Setting workers docker image to: [$WORKER_IMAGE]"

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
  echo "Warning: No Dockerfile or Dockerfile.cron file founds, no image will be built"
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
main_cluster_kustomization_file=$projectdir/kube.out/$CLUSTER_REGION_ID/main/base/kustomization.yaml
main_cluster_env_kustomization_file=$projectdir/kube.out/$CLUSTER_REGION_ID/main/overlays/$ENV/kustomization.yaml
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
worker_cluster_kustomization_file=$projectdir/kube.out/$CLUSTER_REGION_ID/worker/base/kustomization.yaml
worker_cluster_env_kustomization_file=$projectdir/kube.out/$CLUSTER_REGION_ID/worker/overlays/$ENV/kustomization.yaml
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
jobs_cluster_kustomization_file=$projectdir/kube.out/$CLUSTER_REGION_ID/jobs/base/kustomization.yaml
jobs_cluster_env_kustomization_file=$projectdir/kube.out/$CLUSTER_REGION_ID/jobs/overlays/$ENV/kustomization.yaml
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
# Update Config Maps
################
# Run update-configmap if it exists
if [[ -f "$projectdir/kube.out/#-update-configmaps.sh" ]]; then
  echo "Script to update config maps found - Updating them"
  $debug "$projectdir/kube.out/#-update-configmaps.sh"
else
  echo "Skipping config maps update - no ./kube.out/#-update-configmaps.sh script found"
fi

# quit if we only want to do that
[[ ! -z $UPDATE_CONFIG_ONLY && $UPDATE_CONFIG_ONLY != "false" ]] && echo "UPDATE_CONFIG_ONLY given, stopping now" && exit 0

echo ""
echo ""

################
# Docker Image Building
################
if [[ -z ${SKIP_IMAGE_BUILD+x} ]]; then

  if [[ -f "$projectdir/kube.out/#-build-docker-images.sh" ]]; then

    echo "./kube.out/#-build-docker-images.sh script found - Running it"
    $debug "$projectdir/kube.out/#-build-docker-images.sh"

  elif [[ $has_main_dockerfile == "true" || $has_worker_dockerfile == "true" ]]; then

    echo "Preparing to build Dockerfiles"
    echo ""

    if [[ $has_main_dockerfile == "true" ]]; then
      echo "Starting main Dockerfile build"
      $debug docker build -t $APP_IMAGE .

      echo "Pushing built main docker image to GCR."
      $debug docker push $APP_IMAGE
    else
      echo "No main Dockerfile found, skipping..."
    fi

    echo ""

    if [[ $has_worker_dockerfile == "true" ]]; then
      echo "Starting worker Dockerfile build"
      $debug docker build -t $WORKER_IMAGE -f Dockerfile.cron .

      echo "Pushing built worker docker image to GCR."
      $debug docker push $WORKER_IMAGE
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

kustomize_default_svc_folders=(
  "$kuberootdir/kube.out/$CLUSTER_REGION_ID/svc/overlays/$ENV/"
  "$kuberootdir/kube.out/$CLUSTER_REGION_ID/svc/base/"
  "$kuberootdir/kube.out/#/svc/overlays/$ENV/"
  "$kuberootdir/kube.out/#/svc/base/"
)
kustomize_default_jobs_folders=(
  "$kuberootdir/kube.out/$CLUSTER_REGION_ID/jobs/overlays/$ENV/"
  "$kuberootdir/kube.out/$CLUSTER_REGION_ID/jobs/base/"
  "$kuberootdir/kube.out/#/jobs/overlays/$ENV/"
  "$kuberootdir/kube.out/#/jobs/base/"
)
kustomize_default_worker_folders=(
  "$kuberootdir/kube.out/$CLUSTER_REGION_ID/worker/overlays/$ENV/"
  "$kuberootdir/kube.out/$CLUSTER_REGION_ID/worker/base/"
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
export COMMIT_SHA1=$COMMIT_SHA1
export PROJECT_NAME=$PROJECT_NAME
export IMAGES_TAG=$IMAGES_TAG

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
    '$ENV $CLUSTER_REGION_ID $K8S_KUSTOMIZATION_SVC_BASE $K8S_KUSTOMIZATION_JOBS_BASE $K8S_KUSTOMIZATION_WORKER_BASE'

  echo "Using Base Kustomize main folder: $K8S_KUSTOMIZATION_SVC_BASE ($KUSTOMIZE_DEFAULT_SVC_FOLDER)"
  echo "Using Base Kustomize jobs folder: $K8S_KUSTOMIZATION_JOBS_BASE ($KUSTOMIZE_DEFAULT_JOBS_FOLDER)"
  echo "Using Base Kustomize worker folder: $K8S_KUSTOMIZATION_WORKER_BASE ($KUSTOMIZE_DEFAULT_WORKER_FOLDER)"

  echo ""
done

if [[ $has_main_deployment == "true" ]]; then
  kustomize build $kustomize_main_project_folder >$kuberootdir/kube.out/manifests/main.yaml
  IMAGE=$APP_IMAGE $currentdir/replace-envs-on-file.sh -f $kuberootdir/kube.out/manifests/main.yaml -o \
    '$ENV $PROJECT_NAME $COMMIT_SHA1 $IMAGE'
fi

if [[ $has_worker_deployment == "true" ]]; then
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
  
  echo "Calling kubectl apply -f on file $filename"

  $debug kubectl apply -f $filename
done

echo ""
echo ""

echo "Finished deploy 🚀 🚀 🚀"
