FROM google/cloud-sdk

RUN mkdir /scripts
COPY kube-template.yml /scripts/kube-template.yml
COPY kube-deploy.sh /scripts/kube-deploy.sh
