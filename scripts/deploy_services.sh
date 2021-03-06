#!/bin/bash

PULL_POLICY=Always

if [ -z "$CI_REGISTRY_IMAGE" ]; then
    echo "warning: using local build parameters"
    CI_REGISTRY_IMAGE=local-build
    CI_COMMIT_SHA=local-dirty
    PULL_POLICY=Never
fi

GREP_CMD="grep"
if [ "$(uname)" == "Darwin" ]
then
  command -v ggrep >/dev/null 2>&1 || { echo >&2 "OSX requires ggrep but it's not installed.  Please install using homebrew and try again."; exit 1; }
  GREP_CMD="ggrep"
fi

if [[ -f ./target/modules.info ]]; then
  if [ "$(uname)" == "Darwin" ]; then
    spc_modules=($(cut -d$'\n' -f1 ./target/modules.info))
  else
    readarray -t spc_modules < ./target/modules.info
  fi
else
    echo "error: modules.info file is missing"
    exit 1
fi

if [[ -f ./target/version.info ]]; then
    spc_version=$(<./target/version.info)
else
    echo "error: version.info is missing"
    exit 1
fi

KUBE_NAMESPACE="${KUBE_NAMESPACE:-default}"

# Automatically use a namespace-based tiller if available,
# or the cluster-wide installed version if this is possible.
if [ -z "$TILLER_NAMESPACE" ]; then
  if [ -n "$( kubectl get pods --namespace=$KUBE_NAMESPACE -l 'app=helm,name=tiller' -o name)" ]; then
    echo "Found namespace-based tiller installation"
    TILLER_NAMESPACE=$KUBE_NAMESPACE
  elif [ "$(kubectl auth can-i create pods --subresource=portforward --namespace=kube-system)" = "yes" ]; then
    # Can connect with central installed Tiller, use it to deploy the project
    # Note this could mean that deployments have full cluster-admin access!
    TILLER_NAMESPACE="kube-system"
    echo "Found cluster-wide tiller installation"
  elif [ "$(kubectl auth can-i create pods --subresource=portforward --namespace=$NAMESPACE)" = "yes" ]; then
    # Can connect with namespace based Tiller
    TILLER_NAMESPACE="${TILLER_NAMESPACE:-$KUBE_NAMESPACE}"
  else
    echo "No RBAC permission to contact to tiller in either 'kube-system' or '$NAMESPACE'" >&2
    exit 1
  fi
fi

if [ ! -z "$INGRESS_IP" ]; then
  echo "Found INGRESS_IP, generating a nip.io base hostname"
  BASE_HOSTNAME=${INGRESS_IP}.nip.io
fi

if [ ! -z "$UCP_HOSTNAME" ]; then
  echo "Found UCP_HOSTNAME, using that as the base hostname"
  BASE_HOSTNAME=${UCP_HOSTNAME}
fi

if [ -z "$BASE_HOSTNAME" ]; then
  echo "Unable to find BASE_HOSTNAME, did you set the environment variable specific to the platform for this tutorial?"
  echo "GKE users: INGRESS_IP must be set"
  echo "Docker EE users: UCP_HOSTNAME must be set"
  echo ""
  echo "Defaulting to localhost, goodluck"
  BASE_HOSTNAME=localhost
fi

echo "Using tiller in namespace $TILLER_NAMESPACE"

SERVICE_PREFIX=spring-petclinic-

for module in "${spc_modules[@]}"
do
    INGRESS_OVERRIDE=""
    service_name=$(echo "$module" | ${GREP_CMD} -oP "^$SERVICE_PREFIX\K.*")

    echo "Current release:"
    helm ls --tiller-namespace "$TILLER_NAMESPACE" --namespace "$KUBE_NAMESPACE" ${service_name}

    image_path=${CI_REGISTRY_IMAGE}/${module}

    if [[ "$service_name" == "admin-server" ]]; then
        INGRESS_OVERRIDE="ingress.hosts={admin.${BASE_HOSTNAME}},"
    fi

    echo
    echo "Deploying ${image_path} (git ${CI_COMMIT_TAG:-$CI_COMMIT_REF_NAME} $CI_COMMIT_SHA)"
    set -x
    helm upgrade --install --reset-values \
        --tiller-namespace "$TILLER_NAMESPACE" --namespace "$KUBE_NAMESPACE" \
        --set "${INGRESS_OVERRIDE}fullnameOverride=${service_name}" \
        --set "image.repository=${image_path},image.tag=${CI_COMMIT_SHA:-latest},image.pullPolicy=${PULL_POLICY}" \
        --values helm/spring-petclinic-kubernetes/values.${service_name}.yaml \
        ${service_name} helm/spring-petclinic-kubernetes
    { set +x; } 2>/dev/null
done
