FROM docker:17.06.1-ce as static-docker-source
FROM node:10.12 as node
FROM google/cloud-sdk

RUN mkdir -p /opt

RUN \
  apt-get update \
  && apt-get -y install gettext-base \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# Install linkerd and update path
ENV LINKERD2_VERSION edge-18.11.1
RUN curl -sL https://run.linkerd.io/install | sh
ENV PATH="${PATH}:/root/.linkerd2/bin"

# Must match same at https://github.com/nodejs/docker-node/blob/master/10/stretch/Dockerfile#L44
ENV YARN_VERSION 1.10.1

COPY --from=node /opt/yarn-v$YARN_VERSION /opt/yarn-v$YARN_VERSION
COPY --from=node /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/

COPY --from=static-docker-source /usr/local/bin/docker /usr/local/bin/docker

RUN ln -s /opt/yarn-v$YARN_VERSION/bin/yarn /usr/local/bin/yarn

RUN mkdir /scripts
COPY kube-template.yml /scripts/kube-template.yml
COPY kube-cron-template.yml /scripts/kube-cron-template.yml
COPY kube-env-deploy.sh /scripts/kube-env-deploy.sh
