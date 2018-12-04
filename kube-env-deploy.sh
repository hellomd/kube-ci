#! /bin/bash
set -e

if [ -z "$1" ]; then
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

# k8s limits
KUBE_LIMIT_CPU="${KUBE_LIMIT_CPU:-$DEFAULT_KUBE_LIMIT_CPU}"

echo "Deploying ${CIRCLE_PROJECT_REPONAME} $ENV to ${GOOGLE_PROJECT_ID}/$CLUSTER"
echo "Chosen Cluster: $CLUSTER"
echo "Chosen Compute_Zone: $COMPUTE_ZONE"

# Configure deployment
echo ${GOOGLE_AUTH} | base64 -i --decode > ${HOME}/gcp-key.json
gcloud auth activate-service-account --key-file ${HOME}/gcp-key.json
gcloud auth configure-docker
gcloud --quiet config set project ${GOOGLE_PROJECT_ID}
gcloud --quiet config set compute/zone $COMPUTE_ZONE
gcloud --quiet config set container/cluster $CLUSTER
gcloud --quiet container clusters get-credentials $CLUSTER

if [ -e kube.yml ]; then
  cat kube.yml |\
    KUBE_LIMIT_CPU=$KUBE_LIMIT_CPU \
    envsubst > kube2.yml
  mv kube2.yml kube.yml
else
  cat /scripts/kube-template.yml |\
    KUBE_LIMIT_CPU=$KUBE_LIMIT_CPU \
    envsubst > kube.yml
fi

if [ -e kube-cron.yml ]; then
  cat kube-cron.yml |\
    KUBE_LIMIT_CPU=$KUBE_LIMIT_CPU \
    envsubst > kube-cron2.yml
  mv kube-cron2.yml kube-cron.yml
else
  cat /scripts/kube-cron-template.yml |\
    KUBE_LIMIT_CPU=$KUBE_LIMIT_CPU \
    envsubst > kube-cron.yml
fi

# Create deployment
docker build -t us.gcr.io/${GOOGLE_PROJECT_ID}/$CIRCLE_PROJECT_REPONAME:$CIRCLE_SHA1 .
docker tag us.gcr.io/${GOOGLE_PROJECT_ID}/$CIRCLE_PROJECT_REPONAME:$CIRCLE_SHA1 us.gcr.io/${GOOGLE_PROJECT_ID}/$CIRCLE_PROJECT_REPONAME:$CIRCLE_SHA1
docker push us.gcr.io/${GOOGLE_PROJECT_ID}/${CIRCLE_PROJECT_REPONAME}:$CIRCLE_SHA1

if [ -e Dockerfile.cron ]; then
  docker build -t us.gcr.io/${GOOGLE_PROJECT_ID}/$CIRCLE_PROJECT_REPONAME-workers:$CIRCLE_SHA1 -f Dockerfile.cron .
  docker tag us.gcr.io/${GOOGLE_PROJECT_ID}/$CIRCLE_PROJECT_REPONAME-workers:$CIRCLE_SHA1 us.gcr.io/${GOOGLE_PROJECT_ID}/$CIRCLE_PROJECT_REPONAME-workers:$CIRCLE_SHA1
  docker push us.gcr.io/${GOOGLE_PROJECT_ID}/${CIRCLE_PROJECT_REPONAME}-workers:$CIRCLE_SHA1
  kubectl apply -f kube-cron.yml
fi

# Apply deployment with linkerd proxy, unless production env
#services_with_linkerd=('marketplace' 'users' 'authorization' 'memberships')
services_with_linkerd=('none')
if [[ "$ENV" = "development" && " ${services_with_linkerd[@]} " =~ " ${CIRCLE_PROJECT_REPONAME} " ]] || [[ "$ENV" = "staging" && " ${services_with_linkerd[@]} " =~ " ${CIRCLE_PROJECT_REPONAME} " ]]; then
  linkerd version
  cat kube.yml | linkerd inject --proxy-log-level=linkerd2_proxy::control::destination::background::destination_set=trace,linkerd2_proxy::control::destination::background=trace - | kubectl apply -f -
else
  kubectl apply -f kube.yml
fi
