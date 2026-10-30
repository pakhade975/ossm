#!/bin/bash
# Script: build_epp_ibm.sh
# Purpose: Build a native ppc64le/s390x EPP image from GIE source and push it
#          into the target cluster's internal image registry so that
#          config_gie.sh can mirror it via IDMS/ITMS on the test run.
#
# WHY THIS EXISTS:
#   upstream GIE publishes multi-arch images for echo-basic, echo-advanced, and
#   epp — but quay.io/maistra only carries a handful of manually-built
#   ppc64le/s390x tags that lag behind whatever tag a given GIE_VERSION's
#   conformance/resources/base.yaml references. When the tags diverge, this
#   script builds EPP natively (no emulation) from the exact GIE source tree
#   and pushes it into the cluster's own internal registry under the exact tag
#   base.yaml needs. config_gie.sh then wires that internal reference into the
#   cluster's IDMS/ITMS so conformance pods pull from there automatically.
#
# MUST BE RUN ON:
#   A native ppc64le or s390x host (or a host with podman manifest support).
#   The host must have: podman, skopeo, git, oc
#
# WORKFLOW:
#   1. Clone GIE at the exact version under test
#   2. Patch Dockerfile's hardcoded GOARCH=amd64 to the target arch
#   3. Build the image natively via podman
#   4. Expose the cluster's internal registry route (if not already done)
#   5. Push the image into the cluster's internal registry under the exact tag
#      that base.yaml references
#
# After this script completes, run config_gie.sh normally. It will detect the
# image already present in the local mirror namespace and wire it into IDMS/ITMS.
#
# Usage: ./build_epp_ibm.sh [options]
#   See --help for the full list of options.
#
# Examples:
#   # s390x cluster, GIE 1.4.0:
#   ./build_epp_ibm.sh --gie-version 1.4.0 --arch s390x
#
#   # ppc64le cluster, GIE 1.4.0, push to a specific namespace:
#   ./build_epp_ibm.sh --gie-version 1.4.0 --arch ppc64le \
#       --mirror-namespace my-mirror-ns

set -euo pipefail

# ==============================================================================
# Defaults / configuration
# ==============================================================================

GIE_VERSION="${GIE_VERSION:-}"
ARCH="${ARCH:-}"                                         # s390x|ppc64le
GIE_REPO_DIR="${GIE_REPO_DIR:-$(pwd)/gateway-api-inference-extension}"
LOCAL_MIRROR_NAMESPACE="${LOCAL_MIRROR_NAMESPACE:-gie-image-mirror}"
IMAGE_TAG="${IMAGE_TAG:-}"                               # auto-detected from base.yaml if empty
LOCAL_IMAGE_NAME="localhost/epp-${ARCH:-ibm}"
SKIP_BUILD="${SKIP_BUILD:-false}"                        # skip build, just push an existing local image
SKIP_PUSH="${SKIP_PUSH:-false}"                          # build only, do not push to cluster

# ==============================================================================
# Helpers
# ==============================================================================

log() { echo "[$(basename "$0")] $*"; }
die() { echo "[$(basename "$0")] ERROR: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Required:
  --gie-version VERSION   GIE tag to build EPP from (e.g. 1.4.0)
  --arch ARCH             Target architecture: s390x or ppc64le

Optional:
  --image-tag TAG         Image tag to push under in the cluster registry.
                          Defaults to the tag base.yaml references for epp
                          (auto-detected from the checked-out GIE source).
  --mirror-namespace NS   Namespace in the cluster's internal registry to push
                          into (default: ${LOCAL_MIRROR_NAMESPACE})
  --gie-repo-dir PATH     Where to clone/reuse GIE source (default: ./gateway-api-inference-extension)
  --skip-build            Skip the podman build step; expects the image
                          localhost/epp-ARCH:TAG to already exist locally
  --skip-push             Build the image locally but do not push to the cluster
  -h, --help              Show this help

Prerequisites (must be run on a native ppc64le/s390x host):
  - podman
  - skopeo
  - git
  - oc  (logged in to the target cluster as cluster-admin)

After this script completes, run config_gie.sh as normal. It will detect the
image already present in ${LOCAL_MIRROR_NAMESPACE} and wire it into IDMS/ITMS.
EOF
}

# ==============================================================================
# Arg parsing
# ==============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
    --gie-version)        GIE_VERSION="${2:-}";           shift 2 ;;
    --arch)               ARCH="${2:-}";                  shift 2 ;;
    --image-tag)          IMAGE_TAG="${2:-}";             shift 2 ;;
    --mirror-namespace)   LOCAL_MIRROR_NAMESPACE="${2:-}"; shift 2 ;;
    --gie-repo-dir)       GIE_REPO_DIR="${2:-}";          shift 2 ;;
    --skip-build)         SKIP_BUILD="true";              shift   ;;
    --skip-push)          SKIP_PUSH="true";               shift   ;;
    -h|--help)            usage; exit 0 ;;
    *)                    die "unknown argument: $1 (use --help)" ;;
    esac
done

[[ -n "${GIE_VERSION}" ]] || die "--gie-version is required"
[[ -n "${ARCH}" ]]        || die "--arch is required (s390x or ppc64le)"
[[ "${ARCH}" == "s390x" || "${ARCH}" == "ppc64le" ]] || die "--arch must be s390x or ppc64le (got: ${ARCH})"

for bin in podman skopeo git oc; do
    command -v "${bin}" >/dev/null 2>&1 || die "${bin} not found in PATH"
done

if [[ "${SKIP_PUSH}" != "true" ]]; then
    oc whoami >/dev/null 2>&1 || die "not logged into a cluster (oc whoami failed) — log in first"
    log "Logged in as: $(oc whoami)  cluster: $(oc whoami --show-server)"
fi

LOCAL_IMAGE_NAME="localhost/epp-${ARCH}"

# ==============================================================================
# Step 1: Clone / checkout GIE source at the exact version under test
# ==============================================================================

if [[ -d "${GIE_REPO_DIR}/.git" ]]; then
    log "reusing existing GIE checkout at ${GIE_REPO_DIR}"
    git -C "${GIE_REPO_DIR}" fetch --tags
else
    log "cloning gateway-api-inference-extension into ${GIE_REPO_DIR}"
    git clone --no-single-branch \
        https://github.com/kubernetes-sigs/gateway-api-inference-extension.git \
        "${GIE_REPO_DIR}"
fi
git -C "${GIE_REPO_DIR}" checkout "v${GIE_VERSION}"
log "checked out v${GIE_VERSION}"

# ==============================================================================
# Step 2: Auto-detect the image tag base.yaml references for epp
#         (used as the push tag so the cluster gets exactly what base.yaml needs)
# ==============================================================================

BASE_MANIFEST="${GIE_REPO_DIR}/conformance/resources/base.yaml"
EPP_UPSTREAM_REPO="registry.k8s.io/gateway-api-inference-extension/epp"

if [[ -z "${IMAGE_TAG}" ]]; then
    if [[ -f "${BASE_MANIFEST}" ]]; then
        IMAGE_TAG="$(grep -oE "${EPP_UPSTREAM_REPO//./\\.}:[A-Za-z0-9._-]+" \
            "${BASE_MANIFEST}" 2>/dev/null | head -1 | cut -d: -f2 || true)"
    fi
    if [[ -z "${IMAGE_TAG}" ]]; then
        die "could not auto-detect epp image tag from ${BASE_MANIFEST}. Pass --image-tag explicitly."
    fi
    log "auto-detected epp image tag from base.yaml: ${IMAGE_TAG}"
else
    log "using provided image tag: ${IMAGE_TAG}"
fi

FULL_LOCAL_IMAGE="${LOCAL_IMAGE_NAME}:${IMAGE_TAG}"

# ==============================================================================
# Step 3: Patch Dockerfile and build natively
#         The upstream Dockerfile hardcodes ENV GOARCH=amd64 in the builder
#         stage. Replace it with the target arch before building.
# ==============================================================================

if [[ "${SKIP_BUILD}" == "true" ]]; then
    log "skipping build (--skip-build); expecting ${FULL_LOCAL_IMAGE} to exist locally"
    podman image inspect "${FULL_LOCAL_IMAGE}" >/dev/null 2>&1 ||
        die "${FULL_LOCAL_IMAGE} not found locally — build it first or remove --skip-build"
else
    DOCKERFILE="${GIE_REPO_DIR}/Dockerfile"
    DOCKERFILE_PATCHED="${GIE_REPO_DIR}/Dockerfile.${ARCH}"

    [[ -f "${DOCKERFILE}" ]] || die "Dockerfile not found at ${DOCKERFILE}"

    log "patching Dockerfile: replacing GOARCH=amd64 with GOARCH=${ARCH}"
    sed "s/ENV GOARCH=amd64/ENV GOARCH=${ARCH}/" "${DOCKERFILE}" > "${DOCKERFILE_PATCHED}"

    # Sanity check — must be exactly a one-line diff
    diff_lines="$(diff "${DOCKERFILE}" "${DOCKERFILE_PATCHED}" | grep -c '^[<>]' || true)"
    if [[ "${diff_lines}" -ne 2 ]]; then
        log "WARNING: expected a 1-line diff (2 diff lines), got ${diff_lines}."
        log "         The Dockerfile may have changed upstream — review ${DOCKERFILE_PATCHED} before continuing."
        diff "${DOCKERFILE}" "${DOCKERFILE_PATCHED}" || true
    else
        log "Dockerfile patch looks correct (1-line diff)"
    fi

    log "building ${FULL_LOCAL_IMAGE} natively for ${ARCH} (no emulation)"
    podman build \
        -f "${DOCKERFILE_PATCHED}" \
        -t "${FULL_LOCAL_IMAGE}" \
        --arch="${ARCH}" \
        "${GIE_REPO_DIR}"

    log "build complete: ${FULL_LOCAL_IMAGE}"
fi

if [[ "${SKIP_PUSH}" == "true" ]]; then
    log "skipping push (--skip-push)"
    log "image available locally as: ${FULL_LOCAL_IMAGE}"
    exit 0
fi

# ==============================================================================
# Step 4: Ensure the internal registry is Managed and expose its default route
# ==============================================================================

log "ensuring cluster internal registry has a default route..."

# If the registry managementState is Removed (common on clusters without
# persistent storage configured), set it to Managed with emptyDir storage.
# emptyDir is ephemeral but sufficient for the duration of a test run.
MGMT_STATE="$(oc get configs.imageregistry.operator.openshift.io/cluster \
    -o jsonpath='{.spec.managementState}' 2>/dev/null)"
if [[ "${MGMT_STATE}" == "Removed" ]]; then
    log "registry managementState is Removed — setting to Managed with emptyDir storage"
    oc patch configs.imageregistry.operator.openshift.io/cluster --type merge \
        -p '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}},"defaultRoute":true}}'
    log "waiting for image-registry ClusterOperator to become Available..."
    timeout 300 bash -c \
        'until oc get co image-registry -o jsonpath="{.status.conditions[?(@.type==\"Available\")].status}" 2>/dev/null | grep -q True; do sleep 10; done' ||
        die "timed out waiting for image-registry operator to become Available"
elif [[ "$(oc get configs.imageregistry.operator.openshift.io/cluster \
         -o jsonpath='{.spec.defaultRoute}' 2>/dev/null)" != "true" ]]; then
    oc patch configs.imageregistry.operator.openshift.io/cluster \
        --type merge -p '{"spec":{"defaultRoute":true}}'
fi

log "waiting for default-route to appear in openshift-image-registry..."
timeout 180 bash -c \
    'until oc get route default-route -n openshift-image-registry &>/dev/null; do sleep 5; done' ||
    die "timed out waiting for the internal image registry default route"

ROUTE="$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')"
log "internal registry route: ${ROUTE}"

# ==============================================================================
# Step 5: Ensure the mirror namespace exists with anonymous pull access
# ==============================================================================

log "ensuring namespace ${LOCAL_MIRROR_NAMESPACE} exists..."
oc create namespace "${LOCAL_MIRROR_NAMESPACE}" >/dev/null 2>&1 || true

# Grant anonymous pull if the group exists (not available on all clusters)
log "granting anonymous image-pull access on ${LOCAL_MIRROR_NAMESPACE} (if supported)..."
oc adm policy add-role-to-group system:image-puller system:unauthenticated \
    -n "${LOCAL_MIRROR_NAMESPACE}" 2>/dev/null || \
    log "WARNING: system:unauthenticated group not found — anonymous pull not granted (pods will use SA-based pull)"

# ==============================================================================
# Step 6: Log in to the internal registry and push
# ==============================================================================

log "logging skopeo into ${ROUTE} using builder SA token..."
SA_TOKEN="$(oc create token builder -n "${LOCAL_MIRROR_NAMESPACE}" 2>/dev/null \
    || oc serviceaccounts get-token builder -n "${LOCAL_MIRROR_NAMESPACE}")"
skopeo login --tls-verify=false -u builder -p "${SA_TOKEN}" "${ROUTE}"

DEST_IMAGE="${ROUTE}/${LOCAL_MIRROR_NAMESPACE}/epp:${IMAGE_TAG}"
log "pushing ${FULL_LOCAL_IMAGE} -> ${DEST_IMAGE} (preserving ${ARCH} arch metadata)"
# Use skopeo copy with --override-arch so the architecture annotation is
# preserved in the destination manifest. podman push can lose the arch
# annotation causing Exec format error when the node pulls the image.
skopeo copy \
    --dest-tls-verify=false \
    --override-arch "${ARCH}" \
    "containers-storage:${FULL_LOCAL_IMAGE}" \
    "docker://${DEST_IMAGE}"

# ==============================================================================
# Done
# ==============================================================================

cat <<EOF

EPP image pushed successfully.

  source : ${FULL_LOCAL_IMAGE}
  dest   : ${DEST_IMAGE}

The image is now in the cluster's internal registry under namespace
'${LOCAL_MIRROR_NAMESPACE}'. When you run config_gie.sh next, it will
detect this image and wire it into the cluster's IDMS/ITMS automatically —
no extra flags needed.

If you want to verify:
  oc get istag epp:${IMAGE_TAG} -n ${LOCAL_MIRROR_NAMESPACE}

EOF
