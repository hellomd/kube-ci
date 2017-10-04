FROM google/cloud-sdk

RUN \
  apt-get update \
  && apt-get -y install gettext-base \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

RUN mkdir /scripts
COPY kube-template.yml /scripts/kube-template.yml
COPY kube-deploy.sh /scripts/kube-deploy.sh
