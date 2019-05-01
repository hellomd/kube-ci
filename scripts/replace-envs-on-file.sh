#!/bin/bash
set -euo pipefail

usage() {
  echo "Usage: $0 [-f <filepath>] [-d <destination-dir>] [-o]" 1>&2
  echo "-o means overwrite file, instead of saving to dir" 1>&2
  echo "If not overwritten, file will be created on destination dir, or" 1>&2
  echo "if that is not passed, into: \$(dirname \$filepath)/out/" 1>&2
  exit 1
}

filepath=
destination=
overwrite=false

while getopts ":f:d:o" name; do
  case "${name}" in
  f)
    filepath=${OPTARG}
    if [[ ! -f "$filepath" ]]; then
      echo "File $filepath not found"
      exit 1
    fi
    ;;
  d)
    destination=${OPTARG}
    ;;
  o)
    overwrite=true
    ;;
  *)
    usage
    ;;
  esac
done
shift $((OPTIND - 1))

if [ -z "${filepath}" ]; then
  usage
fi

filename=$(basename -- "$filepath")
filedir=$(dirname -- "$filepath")

if [[ -z $destination && $overwrite != "true" ]]; then
  destination=$filedir
fi

printf "Replacing envs in file $filename in dir $filedir"

if [[ $overwrite == "true" ]]; then
  echo ", file will be overriden"
  envsubst <$filepath >$filedir/$filename.out "${@}"
  mv $filedir/$filename.out $filedir/$filename
else
  echo ", output file will go to $filedir/out/$filename"
  envsubst <$filepath >$filedir/out/$filename "${@}"
fi
