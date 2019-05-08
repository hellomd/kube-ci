#!/bin/bash
function get_first_dir_with_kustomization_file() {
  filenames=("$@")
  for filename in "${filenames[@]}"; do
    if [[ -f $filename/kustomization.yaml ]]; then
      echo $filename
      return 0
    fi
  done

  echo "Could not find any file when looking for existing files on ${@}" 1>&2
  return -1
}
