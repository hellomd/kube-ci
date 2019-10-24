FROM node:10.15.3 as node
FROM golang:1.12.4-stretch as go
FROM google/cloud-sdk:245.0.0

RUN mkdir -p /opt

RUN \
  apt-get update \
  # jq is for json manipulation 
  && apt-get -y install gettext-base jq \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# Install linkerd and update path
ENV LINKERD2_VERSION stable-2.3.0
RUN curl -sL https://run.linkerd.io/install | sh
ENV PATH="${PATH}:/root/.linkerd2/bin"

# Node.js
## Must match same at https://github.com/nodejs/docker-node/blob/master/10/stretch/Dockerfile#L44
ENV YARN_VERSION 1.13.0

COPY --from=node /opt/yarn-v$YARN_VERSION /opt/yarn-v$YARN_VERSION
COPY --from=node /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/
RUN ln -s /opt/yarn-v$YARN_VERSION/bin/yarn /usr/local/bin/yarn

# Go
COPY --from=go /usr/local/go /usr/local/go
ENV GOPATH /go
ENV PATH $GOPATH/bin:/usr/local/go/bin:$PATH

RUN mkdir -p "$GOPATH/src" "$GOPATH/bin" && chmod -R 777 "$GOPATH"

# Install Kustomize
ENV KUSTOMIZE_VERSION "v3.3.0"
RUN filename="kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" && \
  echo "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/$filename" && \
  curl -OL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/$filename" && \
  tar xzvf $filename && \
  mv ./kustomize /usr/local/bin/kustomize && \
  kustomize version

# Install yq
RUN \
  go get \
    # yq - yaml processing
    gopkg.in/mikefarah/yq.v2 \
  && ln -s $GOPATH/bin/yq.v2 /usr/local/bin/yq

# Legacy scripts
COPY legacy/ /scripts/

# New deploy stuff
# This will break older deployments
# WORKDIR /kube-ci

COPY kube/ /kube-ci/kube
COPY scripts/ /kube-ci/scripts
