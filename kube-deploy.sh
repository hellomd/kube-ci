#! /bin/bash

echo ${GOOGLE_AUTH} | base64 -i --decode > ${HOME}/gcp-key.json
gcloud auth activate-service-account --key-file ${HOME}/gcp-key.json
gcloud --quiet config set project ${GOOGLE_PROJECT_ID}
gcloud --quiet config set compute/zone ${GOOGLE_COMPUTE_ZONE}
gcloud --quiet config set container/cluster ${GOOGLE_CLUSTER_NAME}
gcloud --quiet container clusters get-credentials ${GOOGLE_CLUSTER_NAME}

if [ ! -e "${CIRCLE_WORKING_DIRECTORY}/kube.yml" ]
    cat /scripts/kube-template.yml | envsubst > "${CIRCLE_WORKING_DIRECTORY}/kube.yml"
then

kubectl apply -f "${CIRCLE_WORKING_DIRECTORY}/kube.yml"
