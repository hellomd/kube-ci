#! /bin/bash
set -e

debug=
# Uncomment to not run any "dangerous" command
# Like building/pushing container images, or applying k8s files
# function debug_cmd() {
#   echo "$> $@"
# }
# debug=debug_cmd

###
# Initial Variables Setup
###

if [[ ! $GOOGLE_PROJECT_ID ]]; then
  echo "Missing GOOGLE_PROJECT_ID env variable"
  exit 1
fi

currentdir="$(dirname "$(readlink -f "$0")")"
projectdir="${PROJECT_DIR:-$(readlink -f .)}"

# Default kube limit for CPU
DEFAULT_KUBE_LIMIT_CPU="40m"
# Default logging level
DEFAULT_LOGGING_LEVEL="info"
DEFAULT_LOGGING_LEVEL_APM="error"

LOGGING_LEVEL=${LOGGING_LEVEL:-$DEFAULT_LOGGING_LEVEL}
LOGGING_LEVEL_APP=${LOGGING_LEVEL_APP:-$LOGGING_LEVEL}
LOGGING_LEVEL_WORKER=${LOGGING_LEVEL_WORKER:-$LOGGING_LEVEL}
LOGGING_LEVEL_CRONJOB=${LOGGING_LEVEL_CRONJOB:-$LOGGING_LEVEL}
LOGGING_LEVEL_APM=${LOGGING_LEVEL_APM:-$DEFAULT_LOGGING_LEVEL_APM}

# Project name
DEFAULT_PROJECT_NAME=${CIRCLE_PROJECT_REPONAME:-$(basename $projectdir)}
PROJECT_NAME=${PROJECT_NAME:-$DEFAULT_PROJECT_NAME}

# Get commit from CircleCI or git sha
COMMIT_SHA1=${CIRCLE_SHA1:-$(git rev-parse HEAD)}

# We only want to run login stuff if running on CIRCLECI
if [[ $SKIP_SETUP != "1" && $CIRCLECI ]]; then
  if [[ -z $1 ]]; then
    echo "No environment argument given, assuming development"
  fi

  # Find environment
  ENV=${1:-development}
  echo export ENV=$ENV

  # Define deployment variables considering environment
  CLUSTER=${GOOGLE_DEVELOPMENT_CLUSTER_NAME}
  COMPUTE_ZONE=${GOOGLE_DEVELOPMENT_COMPUTE_ZONE}

  case "$ENV" in
  "production")
    DEFAULT_KUBE_LIMIT_CPU="100m"
    CLUSTER=${GOOGLE_CLUSTER_NAME_PRODUCTION}
    COMPUTE_ZONE=${GOOGLE_COMPUTE_ZONE_PRODUCTION}
    ;;
  "staging")
    DEFAULT_KUBE_LIMIT_CPU="40m"
    CLUSTER=${GOOGLE_CLUSTER_NAME_STAGING}
    COMPUTE_ZONE=${GOOGLE_COMPUTE_ZONE_STAGING}
    ;;
  "development")
    DEFAULT_KUBE_LIMIT_CPU="40m"
    CLUSTER=${GOOGLE_CLUSTER_NAME_DEVELOPMENT}
    COMPUTE_ZONE=${GOOGLE_COMPUTE_ZONE_DEVELOPMENT}
    ;;
  esac

  echo "Preparing to deploy ${PROJECT_NAME} $ENV to ${GOOGLE_PROJECT_ID}/$CLUSTER"
  echo "Chosen Cluster: $CLUSTER"
  echo "Chosen Compute_Zone: $COMPUTE_ZONE"

  # Configure deployment
  # debug trick does not work with indirections
  if [[ $debug ]]; then
    echo "echo base64-google-auth | base64 -i --decode > ${HOME}/gcp-key.json"
  else
    echo ${GOOGLE_AUTH} | base64 -i --decode > ${HOME}/gcp-key.json
  fi

  $debug gcloud auth activate-service-account --key-file ${HOME}/gcp-key.json
  $debug gcloud auth configure-docker
  $debug gcloud --quiet config set project ${GOOGLE_PROJECT_ID}
  $debug gcloud --quiet config set compute/zone $COMPUTE_ZONE
  $debug gcloud --quiet config set container/cluster $CLUSTER
  $debug gcloud --quiet container clusters get-credentials $CLUSTER

  # Allow to bail out if we are only setting up the environment 
  [[ $SETUP_ONLY == "1" ]] && exit 0
  
  CURRENT_CONTEXT=$(kubectl config current-context)
  
else

  CURRENT_CONTEXT=$(kubectl config current-context)

  # Running locally, get ENV based on current context, using development as default
  ENV="development"

  case "$CURRENT_CONTEXT" in
  "gke_hellomd-181719_us-west1-a_cluster-production")
      ENV="production"
      ;;
  "gke_hellomd-181719_us-west1-a_cluster-staging")
      ENV="staging"
      ;;
  "gke_hellomd-181719_us-central1-a_cluster-development")
      ENV="development"
      ;;
  esac

  echo "Preparing to deploy project ${PROJECT_NAME}"
fi

# New infra with logging and apm on ELK stack
# services_with_new_infra=( 'playground' 'authorization' 'users' 'marketplace' 'backend-for-frontend' 'packing-slip' 'funnel-pdf' 'payments' 'conditions' )
ELASTIC_APM_ACTIVE="true"
ENABLE_STRUCTURED_LOGGING="true"
# Enable above if service is already configured for new infra
# if [[ " ${services_with_new_infra[@]} " =~ " ${PROJECT_NAME} " ]]; then
#   ELASTIC_APM_ACTIVE="true"
#   ENABLE_STRUCTURED_LOGGING="true"
# fi

# k8s limits, this is here because it depends on defaults on CircleCI
KUBE_LIMIT_CPU="${KUBE_LIMIT_CPU:-$DEFAULT_KUBE_LIMIT_CPU}"

# Echo helpful info for debugging
echo "Using kubectl Context: $(kubectl config current-context)"

# Docker images names
APP_IMAGE_NAME=us.gcr.io/${GOOGLE_PROJECT_ID}/$PROJECT_NAME
WORKER_IMAGE_NAME=us.gcr.io/${GOOGLE_PROJECT_ID}/$PROJECT_NAME-workers

IMAGES_TAG=$COMMIT_SHA1

APP_IMAGE=${APP_IMAGE_NAME}:${IMAGES_TAG}
WORKER_IMAGE=${WORKER_IMAGE_NAME}:${IMAGES_TAG}

# export some vars so they are available for other scripts executed from this one, like envsubst
export KUBE_LIMIT_CPU=$KUBE_LIMIT_CPU
export COMMIT_SHA1=$COMMIT_SHA1
export PROJECT_NAME=$PROJECT_NAME
export APP_IMAGE=$APP_IMAGE
export WORKER_IMAGE=$WORKER_IMAGE

export ENABLE_STRUCTURED_LOGGING=$ENABLE_STRUCTURED_LOGGING
export LOGGING_LEVEL_APM=$LOGGING_LEVEL_APM

export ELASTIC_APM_ACTIVE=$ELASTIC_APM_ACTIVE

has_main_deployment=false
has_worker_deployment=false

if [[ -f "$projectdir/Dockerfile" ]]; then
  has_main_deployment=true
fi
if [[ -f "$projectdir/Dockerfile.cron" ]]; then
  has_worker_deployment=true
fi

if [[ $has_main_deployment != true && $has_worker_deployment != true ]]; then
  echo "Warning: No Dockerfile or Dockerfile.cron file founds, no image will be built"
fi

###
# Update Config Maps
###
# Run update-configmap if it exists
if [[ -f "$projectdir/update-configmaps.sh" ]]; then
  echo ""
  echo "Updating config-maps"
  $debug $projectdir/update-configmaps.sh
fi
# quit if we only want to do that
[[ "$UPDATE_CONFIG_ONLY" == "1" ]] && exit 0

###
# Build Docker images
###
# By default we are building the images, unless SKIP_IMAGE_BUILD=1 is given
if [[ "${SKIP_IMAGE_BUILD}" != "1" ]]; then
  echo ""
  echo ""
  echo "Preparing to build dockerfiles"
  
  if [[ $has_main_deployment == true ]]; then
    echo ""
    echo "Starting main Dockerfile build"
    $debug docker build -t $APP_IMAGE .
    echo "Pushing built main docker image to GCR."
    $debug docker push $APP_IMAGE
  else
    echo "No main Dockerfile found, skipping..."
  fi

  if [[ $has_worker_deployment == true ]]; then
    echo ""
    echo "Starting worker Dockerfile build"
    $debug docker build -t $WORKER_IMAGE -f Dockerfile.cron .
    echo "Pushing built worker docker image to GCR."
    $debug docker push $WORKER_IMAGE
  else
    echo "No worker Dockerfile found, skipping..."
  fi
fi

# General function to replace envs in files using envsubst
function envsubst_config_file {
  if [[ ! -f "$1" ]]; then
    echo "File $1 not found"
    exit 1
  fi

  filename=$(basename -- "$1")
  filedir=$(dirname -- "$1")

  echo "Replacing envs in file $filename in dir $filedir"
  envsubst <$1 >$filedir/out/$filename
}

# General function to apply k8s configs, using or not linkerd
function kubectl_apply {
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

###
# App / Worker (old) setup
###

kube_was_created=false
kube_cron_was_created=false

kubedir=$(readlink -f $projectdir/kube)
# @TODO Change extensions to .yaml
kubefile=$(readlink -f $projectdir/kube.yml)
kubefilecron=$(readlink -f $projectdir/kube-cron.yml)

echo ""
echo ""
echo "Kubedir: $kubedir, Kubefile: $kubefile, Kubefilecron: $kubefilecron"

# Create kube files if they don't exist
if [[ $has_main_deployment == true && ! -d "$kubedir" && ! -f "$kubefile" ]]; then
  echo "$kubefile does not exist, using template one."
  kube_was_created=true
  cp $currentdir/kube-template.yml $kubefile
fi
if [[ $has_worker_deployment == true && ! -d "$kubedir" && ! -f "$kubefilecron" ]]; then
  echo "$kubefilecron does not exist, using template one."
  kube_cron_was_created=true
  cp $currentdir/kube-cron-template.yml $kubefilecron
fi

if [[ -d "$kubedir" ]]; then

  export LOGGING_LEVEL=$LOGGING_LEVEL

  # create out dir
  if [[ -d "$kubedir/out" ]]; then
    rm -rf "$kubedir/out"
  fi
  mkdir $kubedir/out
  
  echo ""
  echo "Looking for yaml files on directory $kubedir"
  for kubefile in $kubedir/*.yaml; do
    [[ -f "$kubefile" ]] || continue
    envsubst_config_file $kubefile
  done

  kubectl_apply $kubedir/out/
else
  # create out dir
  if [[ -d "$projectdir/out" ]]; then
    rm -rf "$projectdir/out"
  fi
  mkdir $projectdir/out

  if [[ -f "$projectdir/kube.yml" ]]; then
    export LOGGING_LEVEL=$LOGGING_LEVEL_APP
    envsubst_config_file "$projectdir/kube.yml"
  fi
  
  if [[ -f "$projectdir/kube-cron.yml" ]]; then
    export LOGGING_LEVEL=$LOGGING_LEVEL_WORKER
    envsubst_config_file "$projectdir/kube-cron.yml"
  fi

  kubectl_apply $projectdir/out/
fi

# Remove created files, keep out/ dir since it's recreated every deploy
if [[ $kube_was_created == true ]]; then
  rm $projectdir/kube.yml
fi
if [[ $kube_cron_was_created == true ]]; then
  rm $projectdir/kube-cron.yml
fi

echo ""
echo ""

###
# JOBS (new way for workers)
# The default makes the assumption that the project being built has an Dockerfile
# and that it's a nodejs image, or anything that allows to specify the path to the file
###

create_job() {
  jobdir=$1
  defaultimg=$2

  jobname=$(basename "$jobdir")

  echo "Job found, building it: $jobname"

  # everyday at 8am UTC (around midnight CA)
  DEFAULT_JOB_SCHEDULE='0 8 * * *'
  FILE_JOB_SCHEDULE=''
  [[ -f "$jobdir/.schedule" ]] && FILE_JOB_SCHEDULE=$(cat "$jobdir/.schedule")

  JOB_SCHEDULE=${FILE_JOB_SCHEDULE:-$DEFAULT_JOB_SCHEDULE}

  echo "-> Using job schedule: ${JOB_SCHEDULE}"

  JOB_IMAGE=$defaultimg

  if [[ -f "$jobdir/Dockerfile" ]]; then
    JOB_IMAGE=us.gcr.io/$GOOGLE_PROJECT_ID/$PROJECT_NAME-job-$jobname:$IMAGES_TAG

    echo "-> Found Dockerfile for job, building it"
    $debug docker build -t $JOB_IMAGE $jobdir
    echo "-> Pushing built job docker image to GCR"
    $debug docker push $JOB_IMAGE
  fi

  echo "-> Using docker image: $JOB_IMAGE"

  kubefile=$(readlink -f $jobdir/kube.yaml)
  job_kube_file_created=false

  if [[ -f "$kubefile" ]]; then
    echo "-> Job has a kube.yaml file, using it"
  else
    echo "-> Job has no kube.yaml file, using template one"
    cp $currentdir/kube-cronjob-template.yaml $kubefile
    job_kube_file_created=true
  fi

  # create out dir
  if [[ -d "$jobdir/out" ]]; then
    rm -rf "$jobdir/out"
  fi
  mkdir $jobdir/out

  # Make some new vars visible
  export JOB_NAME=$jobname
  export JOB_SCHEDULE=$JOB_SCHEDULE
  export JOB_IMAGE=$JOB_IMAGE
  # @TODO Allow customization?
  export JOB_FILE="${jobdir}/index.js"

  envsubst_config_file $kubefile
  kubectl_apply $jobdir/out/

  [[ $job_kube_file_created == true ]] && rm "$jobdir/kube.yaml"
}

create_jobs_for_project() {
  jobsdir=$1
  defaultimg=$2

  for jobdir in $jobsdir/*; do
    [[ -d "$jobdir" ]] || continue
    echo ""

    create_job $jobdir $defaultimg
  done
}

if [[ -d "./jobs" && ! -z "$(ls -A ./jobs)" ]]; then
  echo "Preparing cronjobs for project ${PROJECT_NAME}"

  CRONJOBS_DEFAULT_IMAGE=${APP_IMAGE:-"node:10-alpine"}
  export LOGGING_LEVEL=$LOGGING_LEVEL_CRONJOB

  create_jobs_for_project ./jobs $CRONJOBS_DEFAULT_IMAGE
else
  echo "No cronjobs for project ${PROJECT_NAME}"
fi
