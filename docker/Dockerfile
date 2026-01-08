ARG BASE_IMAGE=debian:12

FROM $BASE_IMAGE

LABEL org.opencontainers.image.source="https://github.com/code-tool/argocd-helmfile-plugin"

ENV DEBIAN_FRONTEND=noninteractive
ENV ARGOCD_USER_ID=999

ARG TARGETPLATFORM
ARG BUILDPLATFORM

RUN echo "I am running on final $BUILDPLATFORM, building for $TARGETPLATFORM"

USER root

RUN apt-get update && apt-get install --no-install-recommends -y \
  ca-certificates \
  git git-lfs \
  wget \
  jq && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN groupadd -g $ARGOCD_USER_ID argocd && \
  useradd -r -u $ARGOCD_USER_ID -g argocd argocd && \
  mkdir -p /home/argocd && \
  chown argocd:0 /home/argocd && \
  chmod g=u /home/argocd

# Binary versions
# https://github.com/helm/helm/releases
# Supported Kubernetes Versions 1.33.x - 1.30.x (https://helm.sh/docs/topics/version_skew/)
ARG HELM3_VERSION="v3.19.4"
# https://github.com/helmfile/helmfile/releases
ARG HELMFILE_VERSION="1.1.9"

# https://github.com/getsops/sops/releases
ARG SOPS_VERSION="v3.10.2"
# https://github.com/FiloSottile/age/releases
ARG AGE_VERSION="v1.2.1"

# https://github.com/kubernetes-sigs/kustomize/releases
ARG KUSTOMIZE5_VERSION="5.7.1"
# https://github.com/mikefarah/yq/releases
ARG YQ_VERSION="v4.47.1"

# https://github.com/kubernetes/kubectl/tags
# Compatible with Kubernetes versions ±1 from its version.
ARG KUBECTL_VERSION="v1.33.4"
# https://github.com/kubernetes-sigs/krew/releases/
ARG KREW_VERSION="v0.4.5"
# https://github.com/bitnami-labs/sealed-secrets/releases
ARG KUBESEAL_VERSION="0.31.0"


RUN \
  GO_ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/') && \
  wget -qO-                          "https://get.helm.sh/helm-${HELM3_VERSION}-linux-${GO_ARCH}.tar.gz" | tar zxv --strip-components=1 -C /tmp linux-${GO_ARCH}/helm && mv /tmp/helm /usr/local/bin/helm && \
  wget -qO "/usr/local/bin/sops"     "https://github.com/mozilla/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.${GO_ARCH}" && \
  wget -qO-                          "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-${GO_ARCH}.tar.gz" | tar zxv --strip-components=1 -C /usr/local/bin age/age age/age-keygen && \
  wget -qO-                          "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_${GO_ARCH}.tar.gz" | tar zxv -C /usr/local/bin helmfile && \
  wget -qO "/usr/local/bin/yq"       "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${GO_ARCH}" && \
  wget -qO "/usr/local/bin/kubectl"  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${GO_ARCH}/kubectl" && \
  wget -qO-                          "https://github.com/kubernetes-sigs/krew/releases/download/${KREW_VERSION}/krew-linux_${GO_ARCH}.tar.gz" | tar zxv -C /tmp ./krew-linux_${GO_ARCH} && mv /tmp/krew-linux_${GO_ARCH} /usr/local/bin/kubectl-krew && \
  wget -qO-                          "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-${GO_ARCH}.tar.gz" | tar zxv -C /usr/local/bin kubeseal && \
  wget -qO-                          "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE5_VERSION}/kustomize_v${KUSTOMIZE5_VERSION}_linux_${GO_ARCH}.tar.gz" | tar zxv -C /usr/local/bin kustomize && \
  true

COPY src/*.sh /usr/local/bin/

RUN \
  chown root:root /usr/local/bin/* && chmod 755 /usr/local/bin/*

ENV USER=argocd
USER $ARGOCD_USER_ID

WORKDIR /home/argocd/cmp-server/config/
COPY src/plugin.yaml ./
WORKDIR /home/argocd

# repo-server containers use /helm-working-dir (empty dir volume helm-working-dir)
ENV HELM_CACHE_HOME=/home/argocd/helm/cache
#ENV HELM_CONFIG_HOME=/home/argocd/helm/config
ENV HELM_DATA_HOME=/home/argocd/helm/data
ENV KREW_ROOT=/home/argocd/krew
ENV PATH="${KREW_ROOT}/bin:$PATH"

# plugin versions
# https://github.com/databus23/helm-diff/releases
ARG HELM_DIFF_VERSION="3.13.1"
# https://github.com/aslafy-z/helm-git/releases
ARG HELM_GIT_VERSION="1.4.0"
# https://github.com/jkroepke/helm-secrets/releases
ARG HELM_SECRETS_VERSION="4.6.9"

RUN \
  helm plugin install https://github.com/databus23/helm-diff   --version ${HELM_DIFF_VERSION} && \
  helm plugin install https://github.com/aslafy-z/helm-git     --version ${HELM_GIT_VERSION} && \
  helm plugin install https://github.com/jkroepke/helm-secrets --version ${HELM_SECRETS_VERSION} && \
  kubectl krew update && \
  mkdir -p ${KREW_ROOT}/bin && \
  true

# array is exec form, string is shell form
# this binary in injected via a shared folder with the repo server
#ENTRYPOINT [/var/run/argocd/argocd-cmp-server]
