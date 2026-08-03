#!/usr/bin/env bash
# registry-smoke.sh — proves the shared k3d-managed registry serves both
# clusters and the host (Plan 02, Task 2; FOUND-03). A registry that
# resolves from the host but not from inside a cluster's containerd is the
# exact silent failure this check exists to catch, so this script proves
# it rather than assuming it.
#
# Two names matter here and they are DIFFERENT — mixing them up is the
# usual failure mode with k3d's registry:
#
#   HOST_PUSH_TARGET   — the registry's published host port, reachable from
#                         the Docker daemon and from a host process (this
#                         is what `docker push`/`docker build` on the host
#                         uses, and what the self-hosted CI runner in
#                         Plan 06 will use too, per D-17 — the runner runs
#                         as a host process against the host Docker
#                         daemon). k3d/app-cluster.yaml's registries.create
#                         block was left at its default 0.0.0.0 host
#                         binding (Plan 01's recorded answer to RESEARCH.md
#                         Open Question 3), so this resolves via
#                         `localhost:5000`.
#   IN_CLUSTER_PULL_REF — the registry's k3d-internal container name and
#                         port, `athena-registry:5000`. k3d writes the
#                         containerd mirror config on EVERY node (both
#                         clusters — the app cluster via registries.create,
#                         the platform cluster via registries.use) against
#                         this internal name, not the host-side port. A pod
#                         spec that references `localhost:5000/...` will
#                         fail to pull — "localhost" inside a node's
#                         containerd means the node itself, not the host.
#
# Do not hand-roll a registry container or patch containerd hosts.toml by
# hand (RESEARCH.md Don't Hand-Roll table) — k3d's registries.create/use
# already wires this; this script only proves it works.
#
# Usage: bash scripts/registry-smoke.sh

set -euo pipefail

HOST_PUSH_TARGET="localhost:5000"
IN_CLUSTER_PULL_REF="athena-registry:5000"
IMAGE_NAME="athena/registry-smoke"
IMAGE_TAG="smoke"
HOST_IMAGE="${HOST_PUSH_TARGET}/${IMAGE_NAME}:${IMAGE_TAG}"
CLUSTER_IMAGE="${IN_CLUSTER_PULL_REF}/${IMAGE_NAME}:${IMAGE_TAG}"
TOKEN="ATHENA-REGISTRY-SMOKE-$(date +%s)"
SCRATCH_NS="registry-smoke"
BUILD_DIR="$(mktemp -d)"
CONTEXTS=(k3d-app k3d-platform)

info()  { printf '[registry-smoke] %s\n' "$1"; }
ok()    { printf '\033[32m[registry-smoke] OK: %s\033[0m\n' "$1"; }
fail()  { printf '\033[31m[registry-smoke] FAIL: %s\033[0m\n' "$1"; }

cleanup() {
  rm -rf "${BUILD_DIR}"
  for ctx in "${CONTEXTS[@]}"; do
    kubectl --context "${ctx}" delete namespace "${SCRATCH_NS}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  done
  docker rmi "${HOST_IMAGE}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Build a trivial image on the host from an inline Dockerfile, tagged for
#    the host-side push target.
# ---------------------------------------------------------------------------
info "Building smoke image (token: ${TOKEN})"
cat > "${BUILD_DIR}/Dockerfile" <<EOF
FROM busybox:1.36
LABEL athena.registry-smoke="true"
CMD ["sh", "-c", "echo ${TOKEN}"]
EOF
docker build -t "${HOST_IMAGE}" "${BUILD_DIR}" >/dev/null
ok "Image built: ${HOST_IMAGE}"

# ---------------------------------------------------------------------------
# 2. Push to the host-side target.
# ---------------------------------------------------------------------------
info "Pushing to host-side target ${HOST_PUSH_TARGET}"
docker push "${HOST_IMAGE}" >/dev/null
ok "Pushed ${HOST_IMAGE}"

# ---------------------------------------------------------------------------
# 3. For each cluster: run a short-lived Pod referencing the in-cluster
#    pull reference, wait for it, assert the token appears in its logs,
#    then delete the scratch namespace.
# ---------------------------------------------------------------------------
for ctx in "${CONTEXTS[@]}"; do
  info "Testing pull-and-run in context ${ctx} (in-cluster ref: ${CLUSTER_IMAGE})"

  kubectl --context "${ctx}" delete namespace "${SCRATCH_NS}" --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
  kubectl --context "${ctx}" create namespace "${SCRATCH_NS}" >/dev/null

  cat <<PODSPEC | kubectl --context "${ctx}" -n "${SCRATCH_NS}" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: registry-smoke
  namespace: ${SCRATCH_NS}
spec:
  restartPolicy: Never
  containers:
    - name: registry-smoke
      image: ${CLUSTER_IMAGE}
      imagePullPolicy: Always
PODSPEC

  if ! kubectl --context "${ctx}" -n "${SCRATCH_NS}" wait --timeout=120s pod/registry-smoke \
      --for=jsonpath='{.status.phase}'=Succeeded 2>/dev/null && \
     ! kubectl --context "${ctx}" -n "${SCRATCH_NS}" wait --timeout=5s pod/registry-smoke \
      --for=jsonpath='{.status.phase}'=Running 2>/dev/null; then
    fail "${ctx}: pod did not reach Succeeded or Running"
    kubectl --context "${ctx}" -n "${SCRATCH_NS}" describe pod registry-smoke || true
    exit 1
  fi

  POD_LOGS="$(kubectl --context "${ctx}" -n "${SCRATCH_NS}" logs pod/registry-smoke 2>/dev/null || true)"
  if [[ "${POD_LOGS}" != *"${TOKEN}"* ]]; then
    fail "${ctx}: expected token '${TOKEN}' not found in pod logs"
    printf 'observed logs: %s\n' "${POD_LOGS}"
    exit 1
  fi
  ok "${ctx}: pulled and ran ${CLUSTER_IMAGE}, token found in logs"

  kubectl --context "${ctx}" delete namespace "${SCRATCH_NS}" --wait=true >/dev/null 2>&1
  ok "${ctx}: scratch namespace '${SCRATCH_NS}' cleaned up"
done

# ---------------------------------------------------------------------------
# 4. Assert the registry catalog endpoint on the host port lists the
#    pushed repository — the CI-reachability half of FOUND-03 (D-17: the
#    self-hosted runner runs as a host process against the host Docker
#    daemon, so host reachability is exactly what CI needs).
# ---------------------------------------------------------------------------
CATALOG="$(curl -sS "http://${HOST_PUSH_TARGET}/v2/_catalog" 2>/dev/null || true)"
if [[ "${CATALOG}" == *"${IMAGE_NAME}"* ]]; then
  ok "Registry catalog on ${HOST_PUSH_TARGET} lists ${IMAGE_NAME}"
else
  fail "Registry catalog on ${HOST_PUSH_TARGET} does not list ${IMAGE_NAME}"
  printf 'observed catalog: %s\n' "${CATALOG}"
  exit 1
fi

ok "Registry proven reachable from both clusters (${CONTEXTS[*]}) and the host."
