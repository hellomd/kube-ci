
# Deploy to development (default) env test
export GOOGLE_DEVELOPMENT_CLUSTER_NAME="cluster-development" && export GOOGLE_DEVELOPMENT_COMPUTE_ZONE="czone-development" && ./kube-env-deploy.sh

# Deploy to development env by choice
export GOOGLE_DEVELOPMENT_CLUSTER_NAME="cluster-development" && export GOOGLE_DEVELOPMENT_COMPUTE_ZONE="czone-development" && ./kube-env-deploy.sh development

# Deploy to production env
export GOOGLE_PRODUCTION_CLUSTER_NAME="cluster-production" && export GOOGLE_PRODUCTION_COMPUTE_ZONE="czone-production" && ./kube-env-deploy.sh production
