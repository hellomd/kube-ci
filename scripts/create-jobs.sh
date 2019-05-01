#!/bin/bash
# Remove WORKER related stuff

set -eo pipefail

################
# Initial setup
################
usage() {
  echo "Usage: $0 -j <full path to jobs dir> -i <default image> -b <kustomize base> [-d debug]" 1>&2
  echo "Required Envs:" 1>&2
  echo "- GOOGLE_PROJECT_ID" 1>&2
  echo "- PROJECT_NAME" 1>&2
  echo "- ENV" 1>&2
  echo "- COMMIT_SHA1" 1>&2
  echo "- CLUSTER_ID" 1>&2
  echo "- IMAGES_TAG" 1>&2
  exit 1
}

missing_required_env=false
for required_env in \
  GOOGLE_PROJECT_ID \
  PROJECT_NAME \
  ENV \
  COMMIT_SHA1 \
  CLUSTER_ID \
  IMAGES_TAG; do
  if [ -z "${!required_env}" ]; then
    missing_required_env=true
    echo "$required_env is not set" 1>&2
  fi
done

[[ $missing_required_env == "true" ]] && echo "Missing required environment variables, cannot continue" 1>&2 && usage

# everyday at 8am UTC (around midnight CA)
DEFAULT_JOB_SCHEDULE='0 8 * * *'

currentdir="$(dirname "$(readlink -f "$0")")"
kuberootdir="$(readlink -f "$currentdir/../")"

. $currentdir/utils/get_first_dir_with_kustomization_file.sh

rm -rf $kuberootdir/kube.out/manifests/jobs
mkdir -p $kuberootdir/kube.out/manifests/jobs

jobsdir=
defaultimg=
kustomizebasedir=
debug=
function debug_cmd() {
  echo "$> $@"
}

while getopts ":j:i:b:d" name; do
  case "${name}" in
  j)
    jobsdir=${OPTARG}
    [[ ! -d $jobsdir || ! -n $(ls -A $jobsdir/*/ 2>/dev/null) ]] && echo "jobs folder does not exist or has no jobs" 1>&2 && usage
    ;;
  i)
    defaultimg=${OPTARG}
    ;;
  b)
    # we expect it to 
    kustomizebasedir=${OPTARG}
    [[ ! -f $kustomizebasedir/kustomization.yaml ]] && echo "kustomize base dir does not contain a kustomization.yaml file" 1>&2 && usage
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

# Move jobs folder to out one
projectdir="${PROJECT_DIR:-$(readlink -f .)}"

rm -rf $projectdir/jobs.out
cp -rf $jobsdir $projectdir/jobs.out

jobsdir=$projectdir/jobs.out

function create_job() {
  echo ""
  
  jobdir=$1
  is_global=false
  [[ $2 == "1" ]] && is_global=true

  jobname=$(basename "$jobdir")

  echo "Job found, building it: $jobname"

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
 
  ########
  # Job custom Kustomize stuff
  ########
 
  # if global, we can have different kustomization files per cluster / env 
  if [[ $is_global == "true" ]]; then
    kustomize_job_folders=(
      "$jobdir/kube/$CLUSTER_ID/overlays/$ENV/"
      "$jobdir/kube/$CLUSTER_ID/base/"
      "$jobdir/kube/#/overlays/$ENV/"
      "$jobdir/kube/#/base/"
    )
    kustomizer_job_general_folders=(
      "$jobdir/kube/#/overlays/$ENV/"
      "$jobdir/kube/#/base/"
    )
  # if not global, then we can only have per env
  else
    kustomize_job_folders=(
      "$jobdir/kube/overlays/$ENV/"
      "$jobdir/kube/base/"
    )
    kustomizer_job_general_folders=()
  fi

  kustomize_job_folder=$(
    get_first_dir_with_kustomization_file "${kustomize_job_folders[@]}" 2>/dev/null || echo $kustomizebasedir
  )
  kustomize_job_general_folder=$(
    get_first_dir_with_kustomization_file "${kustomizer_job_general_folders[@]}" 2>/dev/null || echo ""
  )

  for filename in $jobdir/kube/**/*/kustomization.yaml; do
    [ -e "$filename" ] || continue

    base=$kustomizebasedir
    # File is not a general one
    # Identify the general one, if any
    if [[ $is_global == "true" && $filename != "$jobdir/kube/#"* ]]; then
      if [[ -n $kustomize_job_general_folder ]]; then
        base=$kustomize_job_general_folder
      fi
    fi

    export K8S_KUSTOMIZATION_JOBS_BASE=$(realpath --relative-to=$(dirname $filename) $base)

    printf -- "-> "
    $currentdir/replace-envs-on-file.sh -f $filename -o \
      '$ENV $CLUSTER_ID $K8S_KUSTOMIZATION_JOBS_BASE'
  done

  kustomize build $kustomize_job_folder > $kuberootdir/kube.out/manifests/jobs/job-$jobname.yaml

  # Make some new vars visible
  export JOB_NAME=$jobname
  export JOB_SCHEDULE=$JOB_SCHEDULE
  # @TODO Allow customization?
  export JOB_FILE=$(realpath --relative-to=$projectdir $jobdir/index.js | sed 's/jobs.out/jobs/g')

  printf -- "-> "
  IMAGE=$JOB_IMAGE $currentdir/replace-envs-on-file.sh -f $kuberootdir/kube.out/manifests/jobs/job-$jobname.yaml -o \
    '$ENV $PROJECT_NAME $COMMIT_SHA1 $IMAGE $JOB_NAME $JOB_SCHEDULE $JOB_FILE'
}

for jobdir in $jobsdir/\#/*; do
  [[ -d "$jobdir" ]] || continue
  
  create_job $jobdir 1
done

for jobdir in $jobsdir/$CLUSTER_ID/*; do
  [[ -d "$jobdir" ]] || continue
  
  create_job $jobdir 0
done


