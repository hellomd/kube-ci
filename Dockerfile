FROM docker:17.06.1-ce as static-docker-source
FROM google/cloud-sdk

COPY --from=static-docker-source /usr/local/bin/docker /usr/local/bin/docker

RUN \
  apt-get update \
  && apt-get -y install gettext-base \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# Install linkerd and update path
RUN curl -sL https://run.linkerd.io/install | sh
RUN export PATH=$PATH:$HOME/.linkerd2/bin

RUN mkdir /scripts
COPY kube-template.yml /scripts/kube-template.yml
COPY kube-cron-template.yml /scripts/kube-cron-template.yml
COPY kube-env-deploy.sh /scripts/kube-env-deploy.sh
