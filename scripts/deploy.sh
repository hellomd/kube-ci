#!/bin/bash
# Remove WORKER related stuff

set -eo pipefail

################
# Initial setup
################
usage() {
  echo "Usage: $0 [-r <region>] [-e <production|staging|development>] [-d enable debug or not]" 1>&2
  echo "" 1>&2
  echo "-r defaults to \$CLUSTER_REGION_ID, if that is not set, it will default to our main one, hmd" 1>&2
  echo "-e defaults to development" 1>&2
  echo "-d debug mode, disabled by default" 1>&2
  exit 1
}

currentdir="$(dirname "$(readlink -f "$0")")"

ENV=development
# cluster identifier
CLUSTER_REGION_ID=${CLUSTER_REGION_ID:-hmd}

child_args=()

while getopts ":e:r:d" name; do
  case "${name}" in
  e)
    ENV=${OPTARG}
    if ! [[ "$ENV" =~ ^(development|staging|production)$ ]]; then
      usage
    fi
    ;;
  r)
    CLUSTER_REGION_ID=${OPTARG}
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
  echo " - - - - - - - - - - - - - - - - - - - - - - "
  echo "Running: $currentdir/kube-env-deploy.sh -e $ENV -r $region" "${child_args[@]}"
  $currentdir/kube-env-deploy.sh -e $ENV -r $region "${child_args[@]}"
  echo " - - - - - - - - - - - - - - - - - - - - - - "
  echo ""
  echo ""

  # We want to reuse the images built on the first deploy
  export OVERWRITE_APP_IMAGE=${OVERWRITE_APP_IMAGE:-"false"}
  export OVERWRITE_WORKER_IMAGE=${OVERWRITE_WORKER_IMAGE:-"false"}
  export OVERWRITE_JOBS_IMAGES=${OVERWRITE_JOBS_IMAGES:-"false"}
done
