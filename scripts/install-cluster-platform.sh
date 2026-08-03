#!/usr/bin/env bash
# install-cluster-platform.sh — installs the shared cluster-platform layer
# (Gateway API CRDs, Envoy Gateway, cert-manager) into a given kube-context.
# Plan 01, Task 2. Written to take the kube-context as its one argument so
# Plan 02 reuses it verbatim for the platform cluster (CONTEXT.md D-11/D-13).
#
# Order is load-bearing (RESEARCH.md Anti-Patterns): Gateway API CRDs must
# exist before Envoy Gateway's controller starts reconciling, or GatewayClass/
# Gateway/HTTPRoute objects fail with "no matches for kind". k3s bundles none
# of these CRDs itself.
#
# DEVIATION from RESEARCH.md's originally-researched two-step sequence
# (Rule 1 - bug, found live at execution): RESEARCH.md's pattern called for a
# standalone `kubectl apply -f .../gateway-api/releases/download/v1.6.1/
# standard-install.yaml` BEFORE the Envoy Gateway helm install. Under Helm v4
# (this project's pinned Helm major, CLAUDE.md-locked), the `envoyproxy/
# gateway-helm` v1.8.3 chart's own `crds` subchart installs Gateway API CRDs
# via Server-Side Apply as part of `helm install`; SSA-installing over a CRD
# already owned by plain `kubectl apply`'s client-side-apply field manager
# hard-conflicts (`Apply failed with N conflicts: conflicts with
# "kubectl-client-side-apply"`) rather than fast-forwarding, because Helm v4's
# CRD installer took a hard SSA dependency, not documented in RESEARCH.md
# (research predates this project's Helm v4 standardization).
#
# The fix: let the Envoy Gateway chart's `crds.enabled=true` (default) own
# Gateway API CRD installation, in the same atomic `helm install` as Envoy
# Gateway's own native CRDs (EnvoyProxy, ClientTrafficPolicy, etc.) — no
# separate manual apply. This is *more* correct than the researched sequence,
# not just a workaround: it guarantees the installed Gateway API CRD version
# is exactly what the v1.8.3 controller was built and tested against (verified
# live: the chart bundles Gateway API CRDs at bundle-version v1.5.1, not the
# v1.6.1 standalone release RESEARCH.md cited), removing a whole class of
# CRD/controller version-skew bugs that pinning an independent CRD release
# would otherwise risk.
#
#   1. Envoy Gateway (Helm, OCI chart, crds.enabled=true default) — installs
#      both its own native CRDs and a version-matched Gateway API CRD bundle
#      in one release; also the Gateway API implementation on both clusters
#      (D-11), replacing k3s's disabled bundled Traefik.
#   2. cert-manager (Helm, CRDs included) — the in-cluster TLS engine (D-13).
#   3. The mkcert-ca-key-pair TLS secret, read directly from the host's
#      mkcert CAROOT and never copied into the repo working tree — the
#      private key never leaves CAROOT (T-01-01 mitigation).
#
# Safe to run twice: every step checks the desired end state first.
#
# Usage: bash scripts/install-cluster-platform.sh <kube-context>

set -euo pipefail

ENVOY_GATEWAY_VERSION="v1.8.3"
CERT_MANAGER_VERSION="v1.21.1"

info()  { printf '[install-cluster-platform] %s\n' "$1"; }
ok()    { printf '\033[32m[install-cluster-platform] OK: %s\033[0m\n' "$1"; }
fail()  { printf '\033[31m[install-cluster-platform] FAIL: %s\033[0m\n' "$1"; }

if [ $# -lt 1 ]; then
  fail "Usage: $0 <kube-context>"
  exit 1
fi

KCTX="$1"
KC=(kubectl --context "${KCTX}")

if ! "${KC[@]}" get nodes >/dev/null 2>&1; then
  fail "kube-context '${KCTX}' is not reachable. Create the cluster first."
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Envoy Gateway (installs Gateway API CRDs as part of the same release —
#    see the DEVIATION note in this file's header)
# ---------------------------------------------------------------------------
info "Step 1/3: Envoy Gateway ${ENVOY_GATEWAY_VERSION} (Gateway API + native CRDs via crds.enabled=true default)"
if helm --kube-context "${KCTX}" -n envoy-gateway-system status eg >/dev/null 2>&1; then
  ok "Envoy Gateway helm release already installed"
else
  helm --kube-context "${KCTX}" install eg oci://docker.io/envoyproxy/gateway-helm \
    --version "${ENVOY_GATEWAY_VERSION}" \
    -n envoy-gateway-system --create-namespace
fi
if ! "${KC[@]}" get crd gatewayclasses.gateway.networking.k8s.io >/dev/null 2>&1; then
  fail "Gateway API CRDs did not appear after the Envoy Gateway helm install."
  exit 1
fi
info "Waiting for envoy-gateway deployment to become Available..."
"${KC[@]}" wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
ok "Envoy Gateway is Available; Gateway API CRDs present (bundle-version $("${KC[@]}" get crd gatewayclasses.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}'))"

# ---------------------------------------------------------------------------
# 2. cert-manager
# ---------------------------------------------------------------------------
info "Step 2/3: cert-manager ${CERT_MANAGER_VERSION}"
if helm --kube-context "${KCTX}" -n cert-manager status cert-manager >/dev/null 2>&1; then
  ok "cert-manager helm release already installed"
else
  helm --kube-context "${KCTX}" repo add jetstack https://charts.jetstack.io --force-update
  helm --kube-context "${KCTX}" repo update jetstack
  helm --kube-context "${KCTX}" install cert-manager jetstack/cert-manager \
    --version "${CERT_MANAGER_VERSION}" \
    -n cert-manager --create-namespace \
    --set crds.enabled=true
fi
info "Waiting for cert-manager deployments to become Available..."
"${KC[@]}" wait --timeout=5m -n cert-manager deployment/cert-manager --for=condition=Available
"${KC[@]}" wait --timeout=5m -n cert-manager deployment/cert-manager-webhook --for=condition=Available
"${KC[@]}" wait --timeout=5m -n cert-manager deployment/cert-manager-cainjector --for=condition=Available
ok "cert-manager is Available"

# ---------------------------------------------------------------------------
# 3. mkcert CA -> Kubernetes Secret (trust chain root)
# ---------------------------------------------------------------------------
info "Step 3/3: mkcert CA secret (mkcert-ca-key-pair)"
if "${KC[@]}" -n cert-manager get secret mkcert-ca-key-pair >/dev/null 2>&1; then
  ok "mkcert-ca-key-pair secret already exists"
else
  CAROOT="$(mkcert -CAROOT)"
  if [ ! -f "${CAROOT}/rootCA.pem" ] || [ ! -f "${CAROOT}/rootCA-key.pem" ]; then
    fail "mkcert root CA not found at ${CAROOT} — run scripts/bootstrap-host.sh first."
    exit 1
  fi
  # Read directly from CAROOT; never write the key material into the repo
  # working tree (T-01-01 — key stays host-local, never copied or committed).
  "${KC[@]}" -n cert-manager create secret tls mkcert-ca-key-pair \
    --key "${CAROOT}/rootCA-key.pem" \
    --cert "${CAROOT}/rootCA.pem"
  ok "mkcert-ca-key-pair secret created in cert-manager namespace"
fi

ok "Cluster platform layer installed on context '${KCTX}': Gateway API CRDs, Envoy Gateway, cert-manager, mkcert CA secret."
