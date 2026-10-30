#!/bin/bash
# Script: config_gie.sh
# Purpose: Standalone runner for the Gateway API Inference Extension (GIE)
#          conformance flow against OpenShift Service Mesh (OSSM).
#          Mirrors the logic of the Jenkins pipeline (Jenkinsfile).
#
# Assumes:
#   - `oc` is already logged in to the target cluster (cluster-admin).
#   - SSH access to gitlab.cee.redhat.com is configured on this host.
#   - Pull secrets (brew/stage/etc.) are already merged into the cluster's
#     global pull-secret. This script does NOT manage pull secrets.
#
# Usage: ./config_gie.sh [options]
#   See --help for the full list of options.
#
# Examples:
#   # OCP 4.22+, embedded CIO install (amd64/arm64):
#   # istiod/proxy images are auto-fetched from konflux/ossm using SAIL_VERSION
#   ./config_gie.sh \
#       --sail-version 3.5.0 --istio-version 1.31.0 --gie-version 1.4.0
#
#   # OCP 4.22+, embedded CIO install (s390x/ppc64le, pre-GA):
#   # Run build_epp_ibm.sh first, then:
#   ./config_gie.sh \
#       --sail-version 3.5.0 --istio-version 1.31.0 --gie-version 1.4.0
#
#   # OCP 4.22+, override images explicitly instead of auto-fetching:
#   ./config_gie.sh \
#       --sail-version 3.5.0 --istio-version 1.31.0 --gie-version 1.4.0 \
#       --istiod-image registry.redhat.io/openshift-service-mesh/istio-pilot-rhel9@sha256:... \
#       --proxy-image  registry.redhat.io/openshift-service-mesh/istio-proxyv2-rhel9@sha256:...
#
#   # OCP < 4.22, custom catalog/index image (pre-GA):
#   ./config_gie.sh \
#       --sail-version 3.4.3 --istio-version v1.24-latest --gie-version 1.4.0 \
#       --istio-index-image brew.registry.redhat.io/rh-osbs/iib:1172131 \
#       --konflux-ossm-branch 3.4.3
#
#   # OCP < 4.22, using a named catalog source (GA):
#   ./config_gie.sh \
#       --sail-version 3.4.3 --istio-version v1.24-latest --gie-version 1.4.0 \
#       --istio-source redhat-operators

set -euo pipefail

# ==============================================================================
# Defaults / configuration
# ==============================================================================

SAIL_VERSION="${SAIL_VERSION:-}"
ISTIO_VERSION="${ISTIO_VERSION:-}"
GIE_VERSION="${GIE_VERSION:-}"

ISTIO_SOURCE="${ISTIO_SOURCE:-redhat-operators}"
ISTIO_INDEX_IMAGE="${ISTIO_INDEX_IMAGE:-}"
# Istiod and proxy images are resolved dynamically at runtime from the
# konflux/ossm export-images script (see resolve_istio_images() below).
# Override with --istiod-image / --proxy-image if needed.
ISTIOD_IMAGE="${ISTIOD_IMAGE:-}"
PROXY_IMAGE="${PROXY_IMAGE:-}"
# konflux/ossm repo — source of truth for istiod/proxy image sha256 digests.
KONFLUX_REPO_URL="${KONFLUX_REPO_URL:-git@gitlab.cee.redhat.com:istio/konflux/ossm.git}"
KONFLUX_OSSM_BRANCH="${KONFLUX_OSSM_BRANCH:-}"   # e.g. ossm-3.5; auto-derived from SAIL_VERSION if empty

# jenkins-csb-declaration GitLab repo — provides gieGatewayClass.yaml and
# gieDestinationRules.yaml, cloned fresh each run to stay current with upstream.
CSB_REPO_URL="${CSB_REPO_URL:-git@gitlab.cee.redhat.com:istio/servicemesh-qe/jenkins-csb-declaration.git}"
CSB_REPO_BRANCH="${CSB_REPO_BRANCH:-master}"
CSB_REPO_DIR="${CSB_REPO_DIR:-$(pwd)/jenkins-csb-declaration}"

MIRROR_REGISTRY="${MIRROR_REGISTRY:-none}"          # none|stage-registry
SKIP_IBM_MIRROR="${SKIP_IBM_MIRROR:-false}"         # skip ppc64le/s390x IDMS/ITMS
LOCAL_MIRROR_NAMESPACE="${LOCAL_MIRROR_NAMESPACE:-gie-image-mirror}"  # namespace where build_epp_ibm.sh pushed the epp image

GATEWAYCLASS_NAME="${GATEWAYCLASS_NAME:-openshift-default}"
REVISION="${REVISION:-openshift-gateway}"
INGRESS_NS="${INGRESS_NS:-openshift-ingress}"
CIO_NS="${CIO_NS:-openshift-ingress-operator}"
CVO_NS="${CVO_NS:-openshift-cluster-version}"

CLEANUP_BASE_RESOURCES="${CLEANUP_BASE_RESOURCES:-true}"
RUN_TEST="${RUN_TEST:-}"
DEBUG="${DEBUG:-false}"

GIE_REPO_DIR="${GIE_REPO_DIR:-$(pwd)/gateway-api-inference-extension}"
REPORT_DIR="${REPORT_DIR:-$(pwd)/to-archive}"

ISTIOD_DEPLOY="istiod-${REVISION}"
INJECTOR_CM="istio-sidecar-injector-${REVISION}"

# ==============================================================================
# Helpers
# ==============================================================================

log() { echo "[$(basename "$0")] $*"; }
die() { echo "[$(basename "$0")] ERROR: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Required:
  --sail-version VERSION     OSSM/Sail Operator version under test (e.g. 3.4.0)
  --istio-version VERSION    Istio control plane version for the CRD (e.g. v1.30-latest)
  --gie-version VERSION      Gateway API Inference Extension tag to test (e.g. 1.4.0)

Catalog / install options:
  --istio-source NAME        CatalogSource name for servicemeshoperator3
                              (default: ${ISTIO_SOURCE}; ignored on OCP 4.22+)
  --istio-index-image IMAGE  Custom IIB index image; takes precedence over --istio-source.
                              registry-proxy.engineering.redhat.com is auto-rewritten to
                              brew.registry.redhat.io. (ignored on OCP 4.22+)
  --istiod-image IMAGE       Pullspec for the istiod container (OCP 4.22+ only).
                              If omitted, auto-fetched from konflux/ossm using SAIL_VERSION.
  --proxy-image IMAGE        Pullspec for global.proxy / global.proxyInit (OCP 4.22+ only).
                              If omitted, auto-fetched from konflux/ossm using SAIL_VERSION.
  --konflux-ossm-branch REF  Git ref (branch or tag) in konflux/ossm to fetch image digests
                              from. Auto-derived from SAIL_VERSION (e.g. 3.5.0 → ossm-3.5).
                              Override for specific tags (e.g. --konflux-ossm-branch 3.4.3).

GitLab repo options:
  --csb-repo-url URL         GitLab URL for jenkins-csb-declaration
                              (default: ${CSB_REPO_URL})
  --csb-repo-branch BRANCH   Branch to clone (default: ${CSB_REPO_BRANCH})
  --csb-repo-dir PATH        Local clone directory (default: ./jenkins-csb-declaration)

Mirror options:
  --mirror-registry NAME     none|stage-registry (default: ${MIRROR_REGISTRY})
                              Use stage-registry when testing pre-GA OSSM images.
  --skip-ibm-mirror          Skip the ppc64le/s390x IDMS/ITMS
                              (auto-applied when cluster arch is ppc64le/s390x)

General:
  --gateway-class NAME       GatewayClass name (default: ${GATEWAYCLASS_NAME})
  --revision NAME            Istio revision (default: ${REVISION})
  --cleanup-base-resources   true|false passed to conformance suite (default: ${CLEANUP_BASE_RESOURCES})
  --run-test NAME            Run a single conformance test by name
  --debug                    Enable verbose conformance logging
  --gie-repo-dir PATH        Where to clone GIE (default: ./gateway-api-inference-extension)
  --report-dir PATH          Where to write logs/junit (default: ./to-archive)
  -h, --help                 Show this help
EOF
}

version_at_least() {
    local version="${1#v}" req_major="$2" req_minor="$3"
    local major minor
    IFS='.' read -r major minor _ <<<"${version}"
    major="${major:-0}"; minor="${minor:-0}"
    [[ "${major}" =~ ^[0-9]+$ ]] || major=0
    [[ "${minor}" =~ ^[0-9]+$ ]] || minor=0
    ((major > req_major)) || { ((major == req_major)) && ((minor >= req_minor)); }
}

get_ocp_major_version() {
    oc version 2>/dev/null | grep "Server Version" | cut -d: -f2 | cut -d. -f1 | tr -d '[:space:]'
}

get_ocp_y_version() {
    oc version 2>/dev/null | grep "Server Version" | cut -d: -f2 | cut -d. -f2 | tr -d '[:space:]'
}

get_cluster_arch() {
    oc get node -o jsonpath='{.items[0].status.nodeInfo.architecture}'
}

wait_for_cluster_operators() {
    log "waiting for ClusterOperators to stabilize..."
    local deadline=$((SECONDS + 900))
    while ((SECONDS < deadline)); do
        local unstable
        unstable="$(oc get co -o json | jq -r '
            [.items[] | select(
                (.status.conditions[]? | select(.type=="Available"   and .status!="True")) or
                (.status.conditions[]? | select(.type=="Degraded"    and .status=="True"))  or
                (.status.conditions[]? | select(.type=="Progressing" and .status=="True"))
            ) | .metadata.name] | length')"
        [[ "${unstable}" == "0" ]] && { log "all ClusterOperators stable"; return 0; }
        sleep 15
    done
    log "WARNING: timed out waiting for ClusterOperators; continuing anyway"
}

wait_for_mcp_rollout() {
    log "waiting for MachineConfigPools to finish updating..."
    local deadline=$((SECONDS + 1800))
    while ((SECONDS < deadline)); do
        local not_ready
        not_ready="$(oc get mcp -o json | jq -r '
            [.items[] | select(
                (.status.conditions[]? | select(.type=="Updated"  and .status!="True")) or
                (.status.conditions[]? | select(.type=="Degraded" and .status=="True"))
            ) | .metadata.name] | join(",")')"
        if [[ -z "${not_ready}" ]]; then
            log "all MachineConfigPools Updated"
            return 0
        fi
        log "  still waiting on: ${not_ready}"
        sleep 20
    done
    log "WARNING: timed out waiting for MCPs; continuing anyway. Check: oc get mcp"
}

wait_for_catalog_source() {
    local name="$1"
    log "waiting for CatalogSource pod ${name} to be Running..."
    local deadline=$((SECONDS + 900))
    while ((SECONDS < deadline)); do
        oc get pods -n openshift-marketplace --no-headers 2>/dev/null \
            | grep "${name}" | grep -q Running && { log "${name} pod is Running"; return 0; }
        sleep 10
    done
    die "timed out waiting for CatalogSource ${name}"
}

wait_for_operator() {
    local namespace="$1" csv_name="$2"
    log "waiting for CSV '${csv_name}' in ${namespace} to reach Succeeded..."
    local deadline=$((SECONDS + 1200))
    while ((SECONDS < deadline)); do
        oc get csv -n "${namespace}" 2>/dev/null \
            | grep "${csv_name}" | grep -q Succeeded && { log "CSV ${csv_name} Succeeded"; return 0; }
        sleep 10
    done
    die "timed out waiting for CSV ${csv_name} in ${namespace}"
}

resolve_istio_images() {
    # Dynamically fetch istiod/proxy image sha256 digests from the
    # konflux/ossm export-images script for the given SAIL_VERSION.
    #
    # Ref/file derivation from SAIL_VERSION (e.g. 3.5.0 or 3.4.3):
    #   major.minor → 3.5  → branch ossm-3.5, file export-images-v3-5.sh
    #   major.minor → 3.4  → branch ossm-3.4 OR tag (pass --konflux-ossm-branch 3.4.3)
    #                         file export-images-v3-4.sh
    [[ -n "${ISTIOD_IMAGE}" && -n "${PROXY_IMAGE}" ]] && {
        log "using provided --istiod-image and --proxy-image (skipping konflux fetch)"
        return 0
    }

    local major minor mm ref export_file tmp_dir
    IFS='.' read -r major minor _ <<<"${SAIL_VERSION}"
    mm="${major}.${minor}"

    # ref: use --konflux-ossm-branch if provided, otherwise default to ossm-X.Y branch
    ref="${KONFLUX_OSSM_BRANCH:-ossm-${mm}}"
    export_file="bundle-patch/export-images-v${major}-${minor}.sh"

    log "fetching istiod/proxy image digests from ${KONFLUX_REPO_URL} ref=${ref} file=${export_file}"
    tmp_dir="$(mktemp -d)"
    (
        cd "${tmp_dir}"
        git init -q
        git remote add origin "${KONFLUX_REPO_URL}"
        git fetch --depth 1 origin "${ref}" 2>&1 | grep -v "^From" || true
        git show FETCH_HEAD:"${export_file}" > export-images.sh
    ) || die "failed to fetch ${export_file} from ${KONFLUX_REPO_URL} ref=${ref}"

    # Source only the ISTIO_PILOT_* and ISTIO_PROXY_* variables — ignore everything else
    local pilot_var proxy_var istio_minor
    istio_minor="${minor}"
    pilot_var="$(grep -oE "ISTIO_PILOT_[0-9_]+" "${tmp_dir}/export-images.sh" | head -1)"
    proxy_var="$(grep -oE "ISTIO_PROXY_[0-9_]+" "${tmp_dir}/export-images.sh" | head -1)"

    [[ -n "${pilot_var}" ]] || die "could not find ISTIO_PILOT_* variable in ${export_file}"
    [[ -n "${proxy_var}" ]] || die "could not find ISTIO_PROXY_* variable in ${export_file}"

    ISTIOD_IMAGE="$(grep "^export ${pilot_var}=" "${tmp_dir}/export-images.sh" | cut -d'"' -f2)"
    PROXY_IMAGE="$(grep  "^export ${proxy_var}="  "${tmp_dir}/export-images.sh" | cut -d'"' -f2)"

    rm -rf "${tmp_dir}"

    [[ -n "${ISTIOD_IMAGE}" ]] || die "could not parse ${pilot_var} from ${export_file}"
    [[ -n "${PROXY_IMAGE}" ]]  || die "could not parse ${proxy_var} from ${export_file}"

    log "resolved istiod image : ${ISTIOD_IMAGE}"
    log "resolved proxy image  : ${PROXY_IMAGE}"
}

# ==============================================================================
# Arg parsing
# ==============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
    --sail-version)            SAIL_VERSION="${2:-}";           shift 2 ;;
    --istio-version)           ISTIO_VERSION="${2:-}";          shift 2 ;;
    --gie-version)             GIE_VERSION="${2:-}";            shift 2 ;;
    --istio-source)            ISTIO_SOURCE="${2:-}";           shift 2 ;;
    --istio-index-image)       ISTIO_INDEX_IMAGE="${2:-}";      shift 2 ;;
    --istiod-image)            ISTIOD_IMAGE="${2:-}";           shift 2 ;;
    --proxy-image)             PROXY_IMAGE="${2:-}";            shift 2 ;;
    --konflux-ossm-branch)     KONFLUX_OSSM_BRANCH="${2:-}";   shift 2 ;;
    --csb-repo-url)            CSB_REPO_URL="${2:-}";           shift 2 ;;
    --csb-repo-branch)         CSB_REPO_BRANCH="${2:-}";        shift 2 ;;
    --csb-repo-dir)            CSB_REPO_DIR="${2:-}";           shift 2 ;;
    --mirror-registry)         MIRROR_REGISTRY="${2:-}";        shift 2 ;;
    --skip-ibm-mirror)         SKIP_IBM_MIRROR="true";          shift   ;;
    --gateway-class)           GATEWAYCLASS_NAME="${2:-}";      shift 2 ;;
    --revision)
        REVISION="${2:-}"
        ISTIOD_DEPLOY="istiod-${REVISION}"
        INJECTOR_CM="istio-sidecar-injector-${REVISION}"
        shift 2
        ;;
    --cleanup-base-resources)  CLEANUP_BASE_RESOURCES="${2:-}"; shift 2 ;;
    --run-test)                RUN_TEST="${2:-}";               shift 2 ;;
    --debug)                   DEBUG="true";                    shift   ;;
    --gie-repo-dir)            GIE_REPO_DIR="${2:-}";           shift 2 ;;
    --report-dir)              REPORT_DIR="${2:-}";             shift 2 ;;
    -h|--help)                 usage; exit 0 ;;
    *)                         die "unknown argument: $1 (use --help)" ;;
    esac
done

[[ -n "${SAIL_VERSION}" ]]  || die "--sail-version is required"
[[ -n "${ISTIO_VERSION}" ]] || die "--istio-version is required"
[[ -n "${GIE_VERSION}" ]]   || die "--gie-version is required"

for bin in oc kubectl jq git go envsubst; do
    command -v "${bin}" >/dev/null 2>&1 || die "${bin} not found in PATH"
done

oc whoami >/dev/null 2>&1 || die "not logged into a cluster (oc whoami failed)"
log "Logged in as: $(oc whoami)  cluster: $(oc whoami --show-server)"

# Resolve istiod/proxy images dynamically from konflux/ossm repo using
# SAIL_VERSION (skipped if --istiod-image/--proxy-image passed explicitly)
resolve_istio_images

# ==============================================================================
# Detect cluster facts
# ==============================================================================

OCP_MAJOR_VERSION="$(get_ocp_major_version)"
OCP_Y_VERSION="$(get_ocp_y_version)"
CLUSTER_ARCH="$(get_cluster_arch)"

# Embedded install: OCP 5+, or OCP 4.22+ with OSSM >= 3.3
# Matches isSailVersionAtLeast(3,3) && ocpYVersion >= 22 check in Jenkinsfile
EMBEDDED_INSTALL=false
if ((OCP_MAJOR_VERSION >= 5)) || \
   { version_at_least "${SAIL_VERSION}" 3 3 && ((OCP_MAJOR_VERSION == 4)) && ((OCP_Y_VERSION >= 22)); }; then
    EMBEDDED_INSTALL=true
fi

log "OCP version : ${OCP_MAJOR_VERSION}.${OCP_Y_VERSION}"
log "Cluster arch: ${CLUSTER_ARCH}"
log "Install mode: $([[ "${EMBEDDED_INSTALL}" == "true" ]] && echo "embedded (CIO, OCP 4.22+)" || echo "catalog (OLM CatalogSource)")"

# ==============================================================================
# Step 0: Clone jenkins-csb-declaration from GitLab
#         Provides gieGatewayClass.yaml and gieDestinationRules.yaml.
#         Cloned fresh every run to stay in sync with upstream changes.
# ==============================================================================

log "cloning jenkins-csb-declaration (${CSB_REPO_URL}, branch: ${CSB_REPO_BRANCH})"
rm -rf "${CSB_REPO_DIR}"
git clone -b "${CSB_REPO_BRANCH}" "${CSB_REPO_URL}" "${CSB_REPO_DIR}"

GIE_GATEWAYCLASS_YAML="${CSB_REPO_DIR}/resources/install/gieGatewayClass.yaml"
GIE_DESTINATION_RULES_YAML="${CSB_REPO_DIR}/resources/install/gieDestinationRules.yaml"
[[ -f "${GIE_GATEWAYCLASS_YAML}" ]]      || die "not found: ${GIE_GATEWAYCLASS_YAML}"
[[ -f "${GIE_DESTINATION_RULES_YAML}" ]] || die "not found: ${GIE_DESTINATION_RULES_YAML}"

# ==============================================================================
# Step 1: Clone / checkout GIE source early
#         Must happen before the IBM mirror step so we can read base.yaml and
#         know the exact epp tag this GIE_VERSION needs — used to decide
#         whether to prepend the cluster's internal registry mirror for epp.
# ==============================================================================

if [[ -d "${GIE_REPO_DIR}/.git" ]]; then
    log "reusing existing GIE checkout at ${GIE_REPO_DIR}"
    git -C "${GIE_REPO_DIR}" fetch --tags
else
    log "cloning gateway-api-inference-extension into ${GIE_REPO_DIR}"
    git clone --no-single-branch https://github.com/kubernetes-sigs/gateway-api-inference-extension.git "${GIE_REPO_DIR}"
fi
git -C "${GIE_REPO_DIR}" checkout "v${GIE_VERSION}"

BASE_MANIFEST="${GIE_REPO_DIR}/conformance/resources/base.yaml"

# ==============================================================================
# Step 2: IBM mirror sets for ppc64le / s390x clusters
#         Matches 'Check IDMS/ITMS for IBM clusters' stage in Jenkinsfile.
#
#         EPP mirror decision logic:
#           If build_epp_ibm.sh was run before this script, it pushed a
#           natively-built epp image into the cluster's internal registry under
#           gie-image-mirror/epp:TAG (where TAG is what base.yaml references).
#           We detect that via `oc get istag` and, if found, prepend the
#           internal registry mirror AHEAD of quay.io/maistra/epp so the
#           natively-built image is tried first. This is done in the SAME
#           IDMS/ITMS object — a separate object for the same source is NOT
#           reliably merged by the MCO into registries.conf.
# ==============================================================================

# Detect the epp tag base.yaml references and whether it is already in the
# cluster's internal registry (pushed there by build_epp_ibm.sh).
EPP_LOCAL_MIRROR=""
if [[ "${CLUSTER_ARCH}" == "ppc64le" || "${CLUSTER_ARCH}" == "s390x" ]] && \
   [[ "${SKIP_IBM_MIRROR}" != "true" ]] && [[ -f "${BASE_MANIFEST}" ]]; then
    EPP_TAG="$(grep -oE 'registry\.k8s\.io/gateway-api-inference-extension/epp:[A-Za-z0-9._-]+' \
        "${BASE_MANIFEST}" 2>/dev/null | head -1 | cut -d: -f2 || true)"
    if [[ -n "${EPP_TAG}" ]]; then
        if oc get istag "epp:${EPP_TAG}" -n "${LOCAL_MIRROR_NAMESPACE}" >/dev/null 2>&1; then
            EPP_LOCAL_MIRROR="image-registry.openshift-image-registry.svc:5000/${LOCAL_MIRROR_NAMESPACE}/epp"
            log "detected locally-built epp:${EPP_TAG} in ${LOCAL_MIRROR_NAMESPACE} — will use internal registry as primary mirror"
        else
            log "no local epp build found for tag ${EPP_TAG} in ${LOCAL_MIRROR_NAMESPACE} — falling back to quay.io/maistra/epp"
            log "  (run scripts/build_epp_ibm.sh --gie-version ${GIE_VERSION} --arch ${CLUSTER_ARCH} first to use a native build)"
        fi
    fi
fi

# Build the epp mirrors list: internal registry first (if present), then quay.io/maistra
EPP_MIRRORS="quay.io/maistra/epp"
[[ -n "${EPP_LOCAL_MIRROR}" ]] && EPP_MIRRORS="${EPP_LOCAL_MIRROR}, ${EPP_MIRRORS}"

if [[ "${CLUSTER_ARCH}" == "ppc64le" || "${CLUSTER_ARCH}" == "s390x" ]] && \
   [[ "${SKIP_IBM_MIRROR}" != "true" ]]; then
    log "applying IDMS/ITMS for IBM cluster (arch: ${CLUSTER_ARCH})"
    oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: gie-conformance-required-images
spec:
  imageTagMirrors:
    - mirrors: [mirror.gcr.io/library/httpd]
      source: docker.io/library/httpd
    - mirrors: [mirror.gcr.io/curlimages/curl]
      source: docker.io/curlimages/curl
    - mirrors: [mirror.gcr.io/library/nginx]
      source: docker.io/library/nginx
    - mirrors: [mirror.gcr.io/library/redis]
      source: docker.io/library/redis
    - mirrors: [mirror.gcr.io/prom/prometheus]
      source: docker.io/prom/prometheus
    - mirrors: [quay.io/maistra/ratelimit_3.0]
      source: docker.io/envoyproxy/ratelimit
    - mirrors: [quay.io/maistra/fake-registry]
      source: gcr.io/istio-testing/fake-registry
    - mirrors: [quay.io/maistra/fake-registry]
      source: registry.istio.io/testing/fake-registry
    - mirrors: [mirror.gcr.io/openzipkin/zipkin-slim]
      source: docker.io/openzipkin/zipkin-slim
    - mirrors: [quay.io/maistra/jwt-server]
      source: gcr.io/istio-testing/jwt-server
    - mirrors: [quay.io/maistra/jwt-server]
      source: registry.istio.io/testing/jwt-server
    - mirrors: [quay.io/maistra/opentelemetry-collector]
      source: docker.io/otel/opentelemetry-collector
    - mirrors: [quay.io/maistra/echo-basic]
      source: gcr.io/k8s-staging-gateway-api/echo-basic
    - mirrors: [quay.io/maistra/echo-advanced]
      source: gcr.io/k8s-staging-gateway-api/echo-advanced
    - mirrors: [quay.io/maistra/go-httpbin]
      source: docker.io/mccutchen/go-httpbin
    - mirrors: [quay.io/maistra/ext-authz]
      source: gcr.io/istio-testing/ext-authz
      mirrorSourcePolicy: NeverContactSource
    - mirrors: [quay.io/maistra/ext-authz]
      source: registry.istio.io/testing/ext-authz
      mirrorSourcePolicy: NeverContactSource
    - mirrors: [${EPP_MIRRORS}]
      source: registry.k8s.io/gateway-api-inference-extension/epp
---
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: gie-conformance-required-images
spec:
  imageDigestMirrors:
    - mirrors: [mirror.gcr.io/library/httpd]
      source: docker.io/library/httpd
    - mirrors: [mirror.gcr.io/curlimages/curl]
      source: docker.io/curlimages/curl
    - mirrors: [mirror.gcr.io/library/nginx]
      source: docker.io/library/nginx
    - mirrors: [mirror.gcr.io/library/redis]
      source: docker.io/library/redis
    - mirrors: [mirror.gcr.io/prom/prometheus]
      source: docker.io/prom/prometheus
    - mirrors: [quay.io/maistra/ratelimit_3.0]
      source: docker.io/envoyproxy/ratelimit
    - mirrors: [quay.io/maistra/fake-registry]
      source: gcr.io/istio-testing/fake-registry
    - mirrors: [quay.io/maistra/fake-registry]
      source: registry.istio.io/testing/fake-registry
    - mirrors: [mirror.gcr.io/openzipkin/zipkin-slim]
      source: docker.io/openzipkin/zipkin-slim
    - mirrors: [quay.io/maistra/jwt-server]
      source: gcr.io/istio-testing/jwt-server
    - mirrors: [quay.io/maistra/jwt-server]
      source: registry.istio.io/testing/jwt-server
    - mirrors: [quay.io/maistra/opentelemetry-collector]
      source: docker.io/otel/opentelemetry-collector
    - mirrors: [quay.io/maistra/echo-basic]
      source: gcr.io/k8s-staging-gateway-api/echo-basic
    - mirrors: [quay.io/maistra/echo-advanced]
      source: gcr.io/k8s-staging-gateway-api/echo-advanced
    - mirrors: [quay.io/maistra/go-httpbin]
      source: docker.io/mccutchen/go-httpbin
    - mirrors: [quay.io/maistra/ext-authz]
      source: gcr.io/istio-testing/ext-authz
      mirrorSourcePolicy: NeverContactSource
    - mirrors: [quay.io/maistra/ext-authz]
      source: registry.istio.io/testing/ext-authz
      mirrorSourcePolicy: NeverContactSource
    - mirrors: [${EPP_MIRRORS}]
      source: registry.k8s.io/gateway-api-inference-extension/epp
EOF
    wait_for_cluster_operators
    wait_for_mcp_rollout
fi

# ==============================================================================
# Step 2: Product image mirror (stage-registry)
#         Matches 'Apply selected mirror registry' stage in Jenkinsfile.
# ==============================================================================

case "${MIRROR_REGISTRY}" in
none) ;;
stage-registry)
    log "applying stage-registry mirror (registry.redhat.io/openshift-service-mesh* -> registry.stage.redhat.io/...)"
    oc apply -f - <<'EOF'
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: stage-registry
spec:
  imageTagMirrors:
    - mirrors: [registry.stage.redhat.io/openshift-service-mesh]
      source: registry.redhat.io/openshift-service-mesh
    - mirrors: [registry.stage.redhat.io/openshift-service-mesh-tech-preview]
      source: registry.redhat.io/openshift-service-mesh-tech-preview
    - mirrors: [registry.stage.redhat.io/openshift-service-mesh-dev-preview-beta]
      source: registry.redhat.io/openshift-service-mesh-dev-preview-beta
---
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: stage-registry
spec:
  imageDigestMirrors:
    - mirrors: [registry.stage.redhat.io/openshift-service-mesh]
      source: registry.redhat.io/openshift-service-mesh
    - mirrors: [registry.stage.redhat.io/openshift-service-mesh-tech-preview]
      source: registry.redhat.io/openshift-service-mesh-tech-preview
    - mirrors: [registry.stage.redhat.io/openshift-service-mesh-dev-preview-beta]
      source: registry.redhat.io/openshift-service-mesh-dev-preview-beta
EOF
    wait_for_cluster_operators
    wait_for_mcp_rollout
    ;;
*)
    die "invalid --mirror-registry: ${MIRROR_REGISTRY} (expected none|stage-registry)"
    ;;
esac

# ==============================================================================
# Step 3: Custom CatalogSource (OCP < 4.22 with a candidate index image)
#         Matches 'Install Catalog Source from Custom Index Image' stage.
# ==============================================================================

CATALOG_NAME="${ISTIO_SOURCE}"
if [[ "${EMBEDDED_INSTALL}" != "true" && -n "${ISTIO_INDEX_IMAGE}" ]]; then
    CATALOG_NAME="custom-istio-catalog"
    # registry-proxy.engineering.redhat.com -> brew.registry.redhat.io
    CATALOG_IMAGE="${ISTIO_INDEX_IMAGE/registry-proxy.engineering.redhat.com/brew.registry.redhat.io}"
    log "creating CatalogSource ${CATALOG_NAME} from ${CATALOG_IMAGE}"
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOG_NAME}
  namespace: openshift-marketplace
spec:
  displayName: 'RH Custom Istio catalog'
  image: ${CATALOG_IMAGE}
  publisher: grpc
  sourceType: grpc
EOF
    wait_for_catalog_source "${CATALOG_NAME}"
elif [[ "${EMBEDDED_INSTALL}" == "true" && -n "${ISTIO_INDEX_IMAGE}" ]]; then
    log "NOTE: --istio-index-image ignored on OCP 4.22+ (embedded install uses direct image patching)"
fi

# ==============================================================================
# Step 4: GIE CRDs + namespaces
#         Matches 'Install Gateway API Inference Extension CRDs' and
#         'Create test namespaces' stages.
# ==============================================================================

log "applying GIE CRDs (v${GIE_VERSION})"
kubectl kustomize "https://github.com/kubernetes-sigs/gateway-api-inference-extension/config/crd?ref=v${GIE_VERSION}" | kubectl apply -f -

# Namespace layout changed in GIE 1.1 (matches isGieVersionAtLeast check in Jenkinsfile)
if version_at_least "${GIE_VERSION}" 1 1; then
    BACKEND_NS="inference-conformance-app-backend"
    oc create namespace inference-conformance-infra || true
    oc create namespace "${BACKEND_NS}" || true
else
    BACKEND_NS="gateway-conformance-app-backend"
    oc create namespace "${BACKEND_NS}" || true
fi

# ==============================================================================
# Step 5: GatewayClass
#         Matches 'Apply GatewayClass' stage.
#         - Embedded (OCP 4.22+): minimal GatewayClass, no catalog annotations.
#         - Catalog (OCP < 4.22) : apply gieGatewayClass.yaml from GitLab clone
#           with SAIL_VERSION / CATALOG_NAME / ISTIO_VERSION substituted in.
# ==============================================================================

if [[ "${EMBEDDED_INSTALL}" == "true" ]]; then
    log "applying minimal GatewayClass ${GATEWAYCLASS_NAME} (embedded CIO on OCP ${OCP_MAJOR_VERSION}.${OCP_Y_VERSION})"
    oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: ${GATEWAYCLASS_NAME}
spec:
  controllerName: openshift.io/gateway-controller/v1
EOF
    log "skipping CSV check (no CSV in embedded install mode)"
else
    log "applying GatewayClass from ${GIE_GATEWAYCLASS_YAML}"
    log "  SAIL_VERSION=${SAIL_VERSION}  CATALOG_NAME=${CATALOG_NAME}  ISTIO_VERSION=${ISTIO_VERSION}"
    SAIL_VERSION="${SAIL_VERSION}" CATALOG_NAME="${CATALOG_NAME}" ISTIO_VERSION="${ISTIO_VERSION}" \
        envsubst < "${GIE_GATEWAYCLASS_YAML}" | oc apply -f -
    wait_for_operator "openshift-operators" "servicemeshoperator3"
fi

# ==============================================================================
# Step 6: Patch Istio images (OCP 4.22+ embedded install, OCP 4.x only)
#         Matches 'Patch Istio Images for OCP 4.22+' stage.
#         On OCP 5+, CIO manages the control plane — no patching needed.
# ==============================================================================

if [[ "${EMBEDDED_INSTALL}" == "true" ]]; then
    if ((OCP_MAJOR_VERSION >= 5)); then
        log "OCP 5 detected: CIO manages Istiod; waiting for it to provision after GatewayClass creation..."
        timeout 600 bash -c \
            "until oc get deployment/${ISTIOD_DEPLOY} -n ${INGRESS_NS} &>/dev/null; do
                echo 'waiting for ${ISTIOD_DEPLOY} in ${INGRESS_NS}...'; sleep 10
             done" || die "timed out waiting for CIO to provision deployment/${ISTIOD_DEPLOY}"
        timeout 600 bash -c \
            "until oc get configmap/${INJECTOR_CM} -n ${INGRESS_NS} &>/dev/null; do
                echo 'waiting for ${INJECTOR_CM} in ${INGRESS_NS}...'; sleep 10
             done" || die "timed out waiting for CIO to provision configmap/${INJECTOR_CM}"
        log "CIO resources found; preserving their configuration."
    else
        log "patching Istio images for OCP 4.22+"
        log "  ISTIOD_IMAGE: ${ISTIOD_IMAGE}"
        log "  PROXY_IMAGE : ${PROXY_IMAGE}"

        log "waiting for deployment/${ISTIOD_DEPLOY} in ${INGRESS_NS}..."
        timeout 600 bash -c \
            "until oc get deployment/${ISTIOD_DEPLOY} -n ${INGRESS_NS} &>/dev/null; do
                echo 'waiting for ${ISTIOD_DEPLOY}...'; sleep 10
             done" || die "timed out waiting for deployment/${ISTIOD_DEPLOY}"

        log "scaling down cluster-version-operator and ingress-operator"
        oc scale --replicas=0 -n "${CVO_NS}" deployment/cluster-version-operator
        oc scale --replicas=0 -n "${CIO_NS}" deployment/ingress-operator
        oc rollout status -n "${CIO_NS}" deployment/ingress-operator --timeout=120s || true

        log "patching istiod image"
        oc set image -n "${INGRESS_NS}" "deployment/${ISTIOD_DEPLOY}" discovery="${ISTIOD_IMAGE}"

        log "patching proxy image in configmap/${INJECTOR_CM}"
        PATCHED_VALUES=$(oc get -n "${INGRESS_NS}" "configmap/${INJECTOR_CM}" -o json \
            | jq -r --arg proxy "${PROXY_IMAGE}" '
                .data.values |= (
                    fromjson
                    | .global.proxy.image = $proxy
                    | .global.proxyInit.image = $proxy
                    | tojson
                )
                | .data.values')
        oc patch -n "${INGRESS_NS}" "configmap/${INJECTOR_CM}" --type merge \
            -p "$(jq -n --arg values "${PATCHED_VALUES}" '{data: {values: $values}}')"

        log "restarting deployment/${ISTIOD_DEPLOY}"
        oc rollout restart -n "${INGRESS_NS}" "deployment/${ISTIOD_DEPLOY}"
        oc rollout status -n "${INGRESS_NS}" "deployment/${ISTIOD_DEPLOY}" --timeout=300s
        log "Istio images patched successfully"

        cat <<EOF

NOTE: operators left scaled to 0 — restore once testing is complete:
  oc scale --replicas=1 -n ${CVO_NS} deployment/cluster-version-operator
  oc scale --replicas=1 -n ${CIO_NS} deployment/ingress-operator

EOF
    fi
fi

# ==============================================================================
# Step 7: DestinationRules for EPP TLS
#         Matches 'Apply DestinationRules' stage.
#         Applies gieDestinationRules.yaml from GitLab clone with BACKEND_NS
#         substituted in (matches envsubst usage in Jenkinsfile).
# ==============================================================================

log "applying DestinationRules from ${GIE_DESTINATION_RULES_YAML} (BACKEND_NS=${BACKEND_NS})"
BACKEND_NS="${BACKEND_NS}" envsubst < "${GIE_DESTINATION_RULES_YAML}" | oc apply -f -

# ==============================================================================
# Step 8: Patch base.yaml with istio.io/rev label on Gateway resources
#         GIE was already cloned/checked out in Step 1.
#         Matches 'Patch base manifests with revision labels' stage.
# ==============================================================================

BASE_MANIFEST="${GIE_REPO_DIR}/conformance/resources/base.yaml"
if [[ -f "${BASE_MANIFEST}" ]]; then
    log "patching ${BASE_MANIFEST}: adding istio.io/rev=${REVISION} to Gateway resources"
    cp "${BASE_MANIFEST}" "${BASE_MANIFEST}.bak"
    trap 'mv -f "${BASE_MANIFEST}.bak" "${BASE_MANIFEST}" 2>/dev/null || true' EXIT
    awk -v rev="${REVISION}" '
        /^kind: Gateway$/ { in_gateway=1 }
        in_gateway && /^  name:/ {
            print; getline; print
            if ($0 ~ /^  namespace:/) {
                print "  labels:"
                print "    istio.io/rev: " rev
            }
            in_gateway=0; next
        }
        { print }
    ' "${BASE_MANIFEST}.bak" > "${BASE_MANIFEST}"
else
    log "WARNING: ${BASE_MANIFEST} not found; skipping revision label patch"
fi

# ==============================================================================
# Step 9: Run conformance tests
#          Matches 'Execute Gateway Inference Extension' stage.
# ==============================================================================

mkdir -p "${REPORT_DIR}"

if ! command -v go-junit-report &>/dev/null; then
    log "installing go-junit-report"
    go install github.com/jstemmer/go-junit-report/v2@latest
fi
export PATH="${PATH}:$(go env GOPATH)/bin"

test_args=(
    "-gateway-class=${GATEWAYCLASS_NAME}"
    "-cleanup-base-resources=${CLEANUP_BASE_RESOURCES}"
    "-organization=Red Hat"
    "-project=Openshift Service Mesh"
    "-url=https://redhat.com"
    "-contact=@openshift-service-mesh/maintainers"
    "-allow-crds-mismatch=true"
    "-version=${SAIL_VERSION}"
)
[[ "${DEBUG}" == "true" ]] && test_args+=("-debug")
[[ -n "${RUN_TEST}" ]]     && test_args+=("-run-test=${RUN_TEST}")

log "running GIE conformance tests from ${GIE_REPO_DIR}"
(
    cd "${GIE_REPO_DIR}"
    go test -v ./conformance -args "${test_args[@]}" \
        2>&1 | tee "${REPORT_DIR}/conformance.log" \
             | go-junit-report > "${REPORT_DIR}/junit-conformance.xml"
)

log "done."
log "  log   : ${REPORT_DIR}/conformance.log"
log "  junit : ${REPORT_DIR}/junit-conformance.xml"
