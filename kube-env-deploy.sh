#! /bin/bash

if [ -z "$1" ]
  then 
    echo "No environment argument given, assuming development"
fi

# Find environment
ENV=${1:-development}
echo "Deploying ${CIRCLE_PROJECT_REPONAME} $ENV to ${GOOGLE_PROJECT_ID}/${GOOGLE_CLUSTER_NAME}"

# Define deployment variables considering environment
CLUSTER=${GOOGLE_DEVELOPMENT_CLUSTER_NAME}
COMPUTE_ZONE=${GOOGLE_DEVELOPMENT_COMPUTE_ZONE}

case "$ENV" in 
"production")
    CLUSTER=${GOOGLE_CLUSTER_NAME_PRODUCTION}
    COMPUTE_ZONE=${GOOGLE_COMPUTE_ZONE_PRODUCTION}
    ;;
"staging")
    CLUSTER=${GOOGLE_CLUSTER_NAME_STAGING}
    COMPUTE_ZONE=${GOOGLE_COMPUTE_ZONE_STAGING}
    ;;
"development")
    CLUSTER=${GOOGLE_CLUSTER_NAME_DEVELOPMENT}
    COMPUTE_ZONE=${GOOGLE_COMPUTE_ZONE_DEVELOPMENT}
    ;;
esac

echo "Chosen Cluster: $CLUSTER"
echo "Chosen Compute_Zone: $COMPUTE_ZONE"

# Configure deployment
echo ${GOOGLE_AUTH} | base64 -i --decode > ${HOME}/gcp-key.json
gcloud auth activate-service-account --key-file ${HOME}/gcp-key.json
gcloud --quiet config set project ${GOOGLE_PROJECT_ID}
gcloud --quiet config set compute/zone $COMPUTE_ZONE
gcloud --quiet config set container/cluster $CLUSTER
gcloud --quiet container clusters get-credentials $CLUSTER

if [ -e kube.yml ]
then
    cat kube.yml | envsubst > kube2.yml
    mv kube2.yml kube.yml
else
    cat /scripts/kube-template.yml | envsubst > kube.yml
fi


# Create deploymeny
docker build -t us.gcr.io/${GOOGLE_PROJECT_ID}/$CIRCLE_PROJECT_REPONAME:$CIRCLE_SHA1 .
docker tag us.gcr.io/${GOOGLE_PROJECT_ID}/$CIRCLE_PROJECT_REPONAME:$CIRCLE_SHA1 us.gcr.io/${GOOGLE_PROJECT_ID}/$CIRCLE_PROJECT_REPONAME:$ENV
gcloud docker -- push us.gcr.io/${GOOGLE_PROJECT_ID}/${CIRCLE_PROJECT_REPONAME}:$ENV

# Apply deployment
kubectl apply -f kube.yml
