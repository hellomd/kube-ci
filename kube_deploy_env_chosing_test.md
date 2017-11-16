
# Deploy to development (default) env test
export GOOGLE_CLUSTER_NAME_DEVELOPMENT="cluster-development" && export GOOGLE_COMPUTE_ZONE_DEVELOPMENT="czone-development" && ./kube-env-deploy.sh

  ## Expected output
    ```
        No environment argument given, assuming development
        Deploying  development to /
        Chosen Cluster: cluster-development
        Chosen Compute_Zone: czone-development
    ```

# Deploy to development env by choice
export GOOGLE_CLUSTER_NAME_DEVELOPMENT="cluster-development" && export GOOGLE_COMPUTE_ZONE_DEVELOPMENT="czone-development" && ./kube-env-deploy.sh development

  ## Expected output
    ```
        Deploying  development to /
        Chosen Cluster: cluster-development
        Chosen Compute_Zone: czone-development
    ```

# Deploy to production env
export GOOGLE_CLUSTER_NAME_PRODUCTION="cluster-production" && export GOOGLE_COMPUTE_ZONE_PRODUCTION="czone-production" && ./kube-env-deploy.sh production

 ## Expected output
    ```
        Deploying  production to /
        Chosen Cluster: cluster-production
        Chosen Compute_Zone: czone-production
    ```