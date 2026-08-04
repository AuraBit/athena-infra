#!/usr/bin/env bash
# apply-coredns-custom.sh — closes Phase 2 deferred-items.md item 3 and this phase's
# Wave 0 Gap A/Gap B (Plan 03, Task 1): makes `host.k3d.internal` resolve from inside
# both k3d clusters, and makes the app cluster's kube-apiserver reachable from the
# platform cluster's pods.
#
# Gap A (DNS). k3d's own CoreDNS Corefile already imports
# /etc/coredns/custom/*.override — this script derives each cluster's own docker
# bridge gateway IP at run time (docker assigns this at network-creation time; it is
# NEVER a fixed value and must not be hard-coded anywhere in this script or the
# committed manifests) and applies a `coredns-custom` ConfigMap in kube-system on
# that cluster resolving `host.k3d.internal` to it, then rolls CoreDNS so the
# override is genuinely loaded rather than merely present.
#   Re-derive by hand at any time:
#     docker network inspect k3d-app      --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'
#     docker network inspect k3d-platform --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'
#   Observed on this host at authoring time: k3d-app=172.18.0.1, k3d-platform=172.19.0.1
#   (recorded in the task's commit message, not hard-coded here).
#
# Gap B (cross-cluster apiserver reachability). k3d-app and k3d-platform are two
# separate, isolated Docker bridge networks (RESEARCH.md Open Question 3) — proven
# live before this fix: a curl from a platform-cluster pod to the app cluster's
# serverlb over the docker bridge gateway timed out (connection never established).
# The remedy is `docker network connect`: every platform-cluster node container
# (server + every agent — ArgoCD's controller pods are not pinned to a specific
# node) is attached to the k3d-app network, so pod egress traffic to an app-cluster
# address routes out that node's new interface directly onto the app cluster's
# bridge. This is one-directional (platform -> app) and idempotent: each node's
# membership is checked before connecting, never blindly retried.
#
# The app cluster's reachable server URL for ArgoCD's cluster-registration Secret
# (Task 2) is its serverlb, not the k3s server node directly — k3d's own
# load-balancer container is the address the host-side kubeconfig itself resolves
# through, so it is the authoritative in-network entrypoint for this cluster's API:
#     https://<k3d-app-serverlb's IP on the k3d-app network>:6443
# This script prints that resolved address on every run so Task 2 never has to
# re-derive it by hand.
#
# Idempotent and safe to re-run: every step checks current state before mutating it.
#
# Usage: bash scripts/apply-coredns-custom.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."

info()  { printf '[apply-coredns-custom] %s\n' "$1"; }
ok()    { printf '\033[32m[apply-coredns-custom] OK: %s\033[0m\n' "$1"; }
fail()  { printf '\033[31m[apply-coredns-custom] FAIL: %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
# Gap A: apply the coredns-custom hosts override to a given cluster and roll
# CoreDNS so it actually takes effect.
# ---------------------------------------------------------------------------
apply_coredns_override() {
  local cluster="$1" kctx="$2" manifest="$3"
  local gateway

  gateway="$(docker network inspect "k3d-${cluster}" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)" || gateway=""
  if [ -z "${gateway}" ]; then
    fail "could not derive docker bridge gateway for k3d-${cluster} — is the cluster running? (\`k3d cluster list\`)"
    exit 1
  fi
  info "k3d-${cluster} docker bridge gateway: ${gateway}"

  if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx "${kctx}"; then
    fail "kube-context '${kctx}' not found in kubeconfig — remediation: \`k3d cluster create ${cluster} --config k3d/${cluster}-cluster.yaml\` (or re-run the world-rebuild path) before this script"
    exit 1
  fi

  sed "s/__GATEWAY_IP__/${gateway}/" "${manifest}" | kubectl --context "${kctx}" apply -f -
  kubectl --context "${kctx}" -n kube-system rollout restart deployment coredns
  kubectl --context "${kctx}" -n kube-system rollout status deployment coredns --timeout=90s
  ok "coredns-custom applied and CoreDNS rolled on ${kctx}"
}

apply_coredns_override app      k3d-app      "${REPO_ROOT}/clusters/app/coredns-custom.yaml"
apply_coredns_override platform k3d-platform "${REPO_ROOT}/clusters/platform/coredns-custom.yaml"

# ---------------------------------------------------------------------------
# Gap B: attach every platform-cluster node container to the k3d-app docker
# network. Idempotent — each container's current network membership is
# checked first; a container already attached is left alone rather than
# re-run through `docker network connect` (which would otherwise error on
# the second invocation).
# ---------------------------------------------------------------------------
PLATFORM_NODES=(k3d-platform-server-0 k3d-platform-agent-0 k3d-platform-agent-1)
for node in "${PLATFORM_NODES[@]}"; do
  if ! docker inspect "${node}" >/dev/null 2>&1; then
    fail "expected platform-cluster node container '${node}' not found — cluster shape may have changed (k3d/platform-cluster.yaml agents count)"
    exit 1
  fi

  already_connected="$(docker inspect "${node}" --format '{{if index .NetworkSettings.Networks "k3d-app"}}yes{{else}}no{{end}}' 2>/dev/null)"
  if [ "${already_connected}" = "yes" ]; then
    ok "${node} already attached to k3d-app"
  else
    docker network connect k3d-app "${node}"
    ok "${node} attached to k3d-app"
  fi
done

APP_SERVERLB_IP="$(docker inspect k3d-app-serverlb --format '{{(index .NetworkSettings.Networks "k3d-app").IPAddress}}' 2>/dev/null)" || APP_SERVERLB_IP=""
if [ -z "${APP_SERVERLB_IP}" ]; then
  fail "could not resolve k3d-app-serverlb's IP on the k3d-app network"
  exit 1
fi
info "app cluster apiserver reachable from platform-cluster pods at: https://${APP_SERVERLB_IP}:6443"

ok "apply-coredns-custom.sh complete"
