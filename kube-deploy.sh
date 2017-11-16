#! /bin/bash

echo "Deploying ${CIRCLE_PROJECT_REPONAME} to ${GOOGLE_PROJECT_ID}/${GOOGLE_CLUSTER_NAME}"

echo ${GOOGLE_AUTH} | base64 -i --decode > ${HOME}/gcp-key.json
gcloud auth activate-service-account --key-file ${HOME}/gcp-key.json
gcloud --quiet config set project ${GOOGLE_PROJECT_ID}
gcloud --quiet config set compute/zone ${GOOGLE_COMPUTE_ZONE}
gcloud --quiet config set container/cluster ${GOOGLE_CLUSTER_NAME}
gcloud --quiet container clusters get-credentials ${GOOGLE_CLUSTER_NAME}

if [ -e kube.yml ]
then
    cat kube.yml | envsubst > kube2.yml
    mv kube2.yml kube.yml
else
    cat /scripts/kube-template.yml | envsubst > kube.yml
fi

docker build -t us.gcr.io/${GOOGLE_PROJECT_ID}/$CIRCLE_PROJECT_REPONAME:$CIRCLE_SHA1 .
docker tag us.gcr.io/${GOOGLE_PROJECT_ID}/$CIRCLE_PROJECT_REPONAME:$CIRCLE_SHA1 us.gcr.io/${GOOGLE_PROJECT_ID}/$CIRCLE_PROJECT_REPONAME:latest
gcloud docker -- push us.gcr.io/${GOOGLE_PROJECT_ID}/${CIRCLE_PROJECT_REPONAME}

kubectl apply -f kube.yml