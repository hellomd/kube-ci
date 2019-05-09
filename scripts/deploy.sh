#!/bin/bash
# Remove WORKER related stuff

set -eo pipefail

################
# Initial setup
################
# Same than kube-env-deploy.sh one
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

ENV=development
# cluster identifier
CLUSTER_REGION_ID=${CLUSTER_REGION_ID:-hmd}
# Project name is the repo name on GitHub or the current folder name if deploying locally
PROJECT_NAME=${CIRCLE_PROJECT_REPONAME:-$(basename $projectdir)}

child_args=()

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
    child_args+=("-d")
    ;;
  *)
    usage
    ;;
  esac
done
shift $((OPTIND - 1))

IFS=', ' read -r -a cluster_regions <<< "$CLUSTER_REGION_ID"

for region in "${cluster_regions[@]}"; do
  echo "################################################################"
  printf "# DEPLOYING TO ${ENV^^} ON %-32s #\n" ${region^^}
  echo "################################################################"
  echo ""
  echo "Running: $currentdir/kube-env-deploy.sh -e $ENV -r $region" "${child_args[@]}"
  echo " - - - - - - - - - - - - - - - - - - - - - - "
  $currentdir/kube-env-deploy.sh -n $PROJECT_NAME -r $region -e $ENV "${child_args[@]}"
  echo ""
  echo " - - - - - - - - - - - - - - - - - - - - - - "
  echo ""
  echo ""
  echo ""
  echo ""

  # We want to reuse the images built on the first deploy
  export OVERWRITE_APP_IMAGE=${OVERWRITE_APP_IMAGE:-"false"}
  export OVERWRITE_WORKER_IMAGE=${OVERWRITE_WORKER_IMAGE:-"false"}
  export OVERWRITE_JOBS_IMAGES=${OVERWRITE_JOBS_IMAGES:-"false"}
done
