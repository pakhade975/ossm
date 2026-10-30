#!/bin/bash

set -euo pipefail

# Check if the user is logged in
if ! oc whoami &>/dev/null; then
  echo " You are not logged into an OpenShift cluster."
  echo " Please log in using: oc login -u kubeadmin -p <password> --server=https://api.clustername.maistra.upshift.redhat.com:6443 --insecure-skip-tls-verify"
  exit 1
fi

# Optional: Show current user and cluster
echo " Logged in as: $(oc whoami)"
echo " Current cluster: $(oc whoami --show-server)"

SOURCE_ROOT="/root"

cd $SOURCE_ROOT

# Get below details from user
read -p "Enter IMAGE_IIB: " IMAGE_IIB
read -p "Enter OSSM_VERSION: " OSSM_VERSION
read -p "Enter ISTIO_VERSION: " ISTIO_VERSION
read -p "Enter GIE_VERSION: " GIE_VERSION

# Set and export variables
export ISTIO_IMAGE="brew.registry.redhat.io/rh-osbs/iib:$IMAGE_IIB"
export OSSM_VERSION="$OSSM_VERSION"
export ISTIO_VERSION="$ISTIO_VERSION"
export GIE_VERSION="$GIE_VERSION"
export BREW_PULL_SECRET_FILE=$SOURCE_ROOT/brew.json
export REGISTRY_PULL_SECRET_FILE=$SOURCE_ROOT/registry.json

rm -rf $SOURCE_ROOT/jenkins-csb-declaration

git clone -b master git@gitlab.cee.redhat.com:istio/servicemesh-qe/jenkins-csb-declaration.git

cd jenkins-csb-declaration

oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > /tmp/pull-secret.json
jq -s '.[0].auths += .[1].auths | {auths: .[0].auths}' /tmp/pull-secret.json $BREW_PULL_SECRET_FILE > /tmp/new-pull-secret.json
jq -s '.[0].auths += .[1].auths | {auths: .[0].auths}' /tmp/new-pull-secret.json  $REGISTRY_PULL_SECRET_FILE > /tmp/final-pull-secret.json
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/final-pull-secret.json

sleep 30

echo " Applying itms-idms required for GIE"

cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: stage-registry
spec:
  imageTagMirrors:
    - mirrors:
        - mirror.gcr.io/library/httpd
      source: docker.io/library/httpd
    - mirrors:
        - mirror.gcr.io/curlimages/curl
      source: docker.io/curlimages/curl
    - mirrors:
        - mirror.gcr.io/library/nginx
      source: docker.io/library/nginx
    - mirrors:
        - mirror.gcr.io/library/redis
      source: docker.io/library/redis
    - mirrors:
        - mirror.gcr.io/prom/prometheus
      source: docker.io/prom/prometheus
    - mirrors:
        - quay.io/maistra/ratelimit_3.0
      source: docker.io/envoyproxy/ratelimit
    - mirrors:
        - quay.io/maistra/fake-registry
      source: gcr.io/istio-testing/fake-registry
    - mirrors:
        - mirror.gcr.io/openzipkin/zipkin-slim
      source: docker.io/openzipkin/zipkin-slim
    - mirrors:
        - quay.io/maistra/jwt-server
      source: gcr.io/istio-testing/jwt-server
    - mirrors:
        - quay.io/maistra/opentelemetry-collector
      source: docker.io/otel/opentelemetry-collector
    - mirrors:
        - quay.io/maistra/echo-basic
      source: gcr.io/k8s-staging-gateway-api/echo-basic
    - mirrors:
        - quay.io/maistra/echo-advanced
      source: gcr.io/k8s-staging-gateway-api/echo-advanced
    - mirrors:
        - quay.io/maistra/go-httpbin
      source: docker.io/mccutchen/go-httpbin
    - mirrors:
        - quay.io/maistra/ext-authz
      source: gcr.io/istio-testing/ext-authz
      mirrorSourcePolicy: NeverContactSource
    - mirrors:
        - quay.io/maistra/epp
      source: registry.k8s.io/gateway-api-inference-extension/epp
      imagePullPolicy: Always
    - mirrors:
        - registry.stage.redhat.io/openshift-service-mesh
      source: registry.redhat.io/openshift-service-mesh
    - mirrors:
        - registry.stage.redhat.io/openshift-service-mesh-tech-preview
      source: registry.redhat.io/openshift-service-mesh-tech-preview
    - mirrors:
        - registry.stage.redhat.io/openshift-service-mesh-dev-preview-beta
      source: registry.redhat.io/openshift-service-mesh-dev-preview-beta
---
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: stage-registry
spec:
  imageDigestMirrors:
    - mirrors:
        - mirror.gcr.io/library/httpd
      source: docker.io/library/httpd
    - mirrors:
        - mirror.gcr.io/curlimages/curl
      source: docker.io/curlimages/curl
    - mirrors:
        - mirror.gcr.io/library/nginx
      source: docker.io/library/nginx
    - mirrors:
        - mirror.gcr.io/library/redis
      source: docker.io/library/redis
    - mirrors:
        - mirror.gcr.io/prom/prometheus
      source: docker.io/prom/prometheus
    - mirrors:
        - quay.io/maistra/ratelimit_3.0
      source: docker.io/envoyproxy/ratelimit
    - mirrors:
        - quay.io/maistra/fake-registry
      source: gcr.io/istio-testing/fake-registry
    - mirrors:
        - mirror.gcr.io/openzipkin/zipkin-slim
      source: docker.io/openzipkin/zipkin-slim
    - mirrors:
        - quay.io/maistra/jwt-server
      source: gcr.io/istio-testing/jwt-server
    - mirrors:
        - quay.io/maistra/opentelemetry-collector
      source: docker.io/otel/opentelemetry-collector
    - mirrors:
        - quay.io/maistra/echo-basic
      source: gcr.io/k8s-staging-gateway-api/echo-basic
    - mirrors:
        - quay.io/maistra/echo-advanced
      source: gcr.io/k8s-staging-gateway-api/echo-advanced
    - mirrors:
        - quay.io/maistra/go-httpbin
      source: docker.io/mccutchen/go-httpbin
    - mirrors:
        - quay.io/maistra/ext-authz
      source: gcr.io/istio-testing/ext-authz
      mirrorSourcePolicy: NeverContactSource
    - mirrors:
        - quay.io/maistra/epp
      source: registry.k8s.io/gateway-api-inference-extension/epp
      imagePullPolicy: Always
    - mirrors:
        - registry.stage.redhat.io/openshift-service-mesh
      source: registry.redhat.io/openshift-service-mesh
    - mirrors:
        - registry.stage.redhat.io/openshift-service-mesh-tech-preview
      source: registry.redhat.io/openshift-service-mesh-tech-preview
    - mirrors:
        - registry.stage.redhat.io/openshift-service-mesh-dev-preview-beta
      source: registry.redhat.io/openshift-service-mesh-dev-preview-beta
EOF

echo "Waiting for all MachineConfigPools to be updated..."

for mcp in $(oc get mcp -o name); do
  echo "Waiting for $mcp..."
  until oc get $mcp -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}' | grep -q True; do
    sleep 10
  done
  echo "$mcp is updated."
done

echo "All MCPs updated successfully."

echo "Setting Up Istio CatalogSource"

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: istio-catalog
  namespace: openshift-marketplace
spec:
  displayName: istio-catalog
  image: $ISTIO_IMAGE
  publisher: grpc
  sourceType: grpc
EOF

sleep 30

kubectl kustomize "https://github.com/kubernetes-sigs/gateway-api-inference-extension/config/crd?ref=v${GIE_VERSION}" | kubectl apply -f -

sleep 30

NS="gateway-conformance-app-backend"

if kubectl get ns "$NS" >/dev/null 2>&1; then
  echo "Namespace $NS exists. Deleting..."
  kubectl delete ns "$NS" --wait=true
fi

kubectl create namespace $NS

sleep 30

SAIL_VERSION="$OSSM_VERSION"
CATALOG_NAME="istio-catalog"

sed -i \
  -e "s|\${SAIL_VERSION}|${SAIL_VERSION}|g" \
  -e "s|\${CATALOG_NAME}|${CATALOG_NAME}|g" \
  -e "s|\${ISTIO_VERSION}|${ISTIO_VERSION}|g" \
  "$SOURCE_ROOT/jenkins-csb-declaration/resources/install/gieGatewayClass.yaml"

oc apply -f $SOURCE_ROOT/jenkins-csb-declaration/resources/install/gieGatewayClass.yaml

sleep 30

oc apply -f $SOURCE_ROOT/jenkins-csb-declaration/resources/install/gieDestinationRules.yaml

sleep 30

cd $SOURCE_ROOT

rm -rf $SOURCE_ROOT/gateway-api-inference-extension

git clone --no-single-branch https://github.com/kubernetes-sigs/gateway-api-inference-extension.git
cd gateway-api-inference-extension
git fetch --tags
git checkout v${GIE_VERSION}

echo "Configured GIE Testing"
