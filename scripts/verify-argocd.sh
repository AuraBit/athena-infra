#!/usr/bin/env bash
# verify-argocd.sh — CD-01/CD-02/D-33 standing assertions for the ArgoCD
# hub-and-spoke deployment (Plan 03-01, Task 3).
#
# Asserts four read-only things, plus one deliberate write (the drift-revert
# drill itself — a self-heal claim that is never actually exercised is
# precisely the scan-theater failure this estate exists to avoid):
#   1. Hub-and-spoke placement — ArgoCD lives on the platform cluster only.
#   2. Remote registration — the app cluster is a registered remote
#      destination, not the in-cluster default.
#   3. Sync and health — every Application is Synced/Healthy. An empty
#      result set is a FAIL, never a vacuous green (same non-vacuous-pass
#      discipline verify-network.sh already enforces).
#   4. Sync policy — every Application has selfHeal AND prune enabled
#      (D-33), so a future plan cannot quietly weaken prod's posture
#      without turning this red.
#   5. The drift-revert drill: scales the live media Deployment away from
#      its git-declared replica count, polls until ArgoCD's selfHeal
#      reverts it, and records the observed elapsed time. Bounded by an
#      explicit timeout; a timeout is a FAIL with the observed value
#      printed, never a silent hang. A trap restores the resource if this
#      script dies mid-drill, so a killed run never leaves the cluster
#      drifted.
#
# Deliberately not using `set -e` (mirrors verify-localstack.sh /
# verify-network.sh): every fallible command is captured into a variable
# first so one failing check never aborts the ones after it;
# scripts/verify.sh (this script's dispatcher) is what turns any FAIL here
# into a non-zero process exit.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESTATE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GITOPS_RENDERED_FILE="${ESTATE_ROOT}/athena-gitops/envs/dev/media/all.yaml"
PLATFORM_CTX="k3d-platform"
APP_CTX="k3d-app"
ARGOCD_NS="argocd"
DEV_NS="dev"
DRIFT_TIMEOUT_SECONDS=60

PASS_COUNT=0
FAIL_COUNT=0

check() {
  local name="$1" status="$2" observed="${3:-}"
  if [ "${status}" -eq 0 ]; then
    printf '\033[32mPASS\033[0m  %s\n' "${name}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    printf '\033[31mFAIL\033[0m  %s\n' "${name}"
    printf '      observed: %s\n' "${observed}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ---------------------------------------------------------------------------
# 1. Hub-and-spoke placement (CD-01)
# ---------------------------------------------------------------------------
ARGOCD_SERVER_AVAILABLE="$(kubectl --context "${PLATFORM_CTX}" -n "${ARGOCD_NS}" get deploy argocd-server -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" || ARGOCD_SERVER_AVAILABLE=""
APP_HAS_ARGOCD_NS="$(kubectl --context "${APP_CTX}" get ns "${ARGOCD_NS}" -o name 2>/dev/null)" || APP_HAS_ARGOCD_NS=""

if [ "${ARGOCD_SERVER_AVAILABLE}" = "True" ] && [ -z "${APP_HAS_ARGOCD_NS}" ]; then
  check "hub-and-spoke placement: argocd-server available on ${PLATFORM_CTX}, no argocd namespace on ${APP_CTX}" 0
else
  check "hub-and-spoke placement: argocd-server available on ${PLATFORM_CTX}, no argocd namespace on ${APP_CTX}" 1 \
    "argocd-server Available=[${ARGOCD_SERVER_AVAILABLE:-<empty>}] app-cluster-argocd-ns=[${APP_HAS_ARGOCD_NS:-<none>}]"
fi

# ---------------------------------------------------------------------------
# 2. Remote registration (CD-01)
# ---------------------------------------------------------------------------
CLUSTER_SECRET_LABEL="$(kubectl --context "${PLATFORM_CTX}" -n "${ARGOCD_NS}" get secret app-cluster-secret -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/secret-type}' 2>/dev/null)" || CLUSTER_SECRET_LABEL=""
MEDIA_DEST_SERVER="$(kubectl --context "${PLATFORM_CTX}" -n "${ARGOCD_NS}" get application media-dev -o jsonpath='{.spec.destination.server}' 2>/dev/null)" || MEDIA_DEST_SERVER=""

if [ "${CLUSTER_SECRET_LABEL}" = "cluster" ] && [ -n "${MEDIA_DEST_SERVER}" ] && [ "${MEDIA_DEST_SERVER}" != "https://kubernetes.default.svc" ]; then
  check "remote registration: cluster Secret labelled, media-dev destination is a real remote URL (${MEDIA_DEST_SERVER})" 0
else
  check "remote registration: cluster Secret labelled, media-dev destination is a real remote URL" 1 \
    "secret-type-label=[${CLUSTER_SECRET_LABEL:-<empty>}] media-dev.destination.server=[${MEDIA_DEST_SERVER:-<empty>}]"
fi

# ---------------------------------------------------------------------------
# 3. Sync and health — non-vacuous (an empty Application list is a FAIL)
# ---------------------------------------------------------------------------
APP_NAMES="$(kubectl --context "${PLATFORM_CTX}" -n "${ARGOCD_NS}" get applications -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)" || APP_NAMES=""

if [ -z "${APP_NAMES}" ]; then
  check "sync/health: every Application is Synced and Healthy" 1 \
    "zero Applications found in ${ARGOCD_NS} on ${PLATFORM_CTX} — an empty result set is a FAIL, never a vacuous green"
else
  UNHEALTHY=()
  for app in ${APP_NAMES}; do
    SYNC_STATUS="$(kubectl --context "${PLATFORM_CTX}" -n "${ARGOCD_NS}" get application "${app}" -o jsonpath='{.status.sync.status}' 2>/dev/null)" || SYNC_STATUS=""
    HEALTH_STATUS="$(kubectl --context "${PLATFORM_CTX}" -n "${ARGOCD_NS}" get application "${app}" -o jsonpath='{.status.health.status}' 2>/dev/null)" || HEALTH_STATUS=""
    if [ "${SYNC_STATUS}" != "Synced" ] || [ "${HEALTH_STATUS}" != "Healthy" ]; then
      UNHEALTHY+=("${app}=(sync=${SYNC_STATUS:-<empty>},health=${HEALTH_STATUS:-<empty>})")
    fi
  done
  if [ "${#UNHEALTHY[@]}" -eq 0 ]; then
    check "sync/health: every Application is Synced and Healthy (${APP_NAMES})" 0
  else
    check "sync/health: every Application is Synced and Healthy" 1 "$(printf '%s; ' "${UNHEALTHY[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Sync policy — selfHeal AND prune on every Application (D-33)
# ---------------------------------------------------------------------------
if [ -z "${APP_NAMES}" ]; then
  check "sync policy: every Application has selfHeal and prune enabled" 1 \
    "zero Applications found — nothing to assert (see check 3 above)"
else
  BAD_POLICY=()
  for app in ${APP_NAMES}; do
    SELF_HEAL="$(kubectl --context "${PLATFORM_CTX}" -n "${ARGOCD_NS}" get application "${app}" -o jsonpath='{.spec.syncPolicy.automated.selfHeal}' 2>/dev/null)" || SELF_HEAL=""
    PRUNE="$(kubectl --context "${PLATFORM_CTX}" -n "${ARGOCD_NS}" get application "${app}" -o jsonpath='{.spec.syncPolicy.automated.prune}' 2>/dev/null)" || PRUNE=""
    if [ "${SELF_HEAL}" != "true" ] || [ "${PRUNE}" != "true" ]; then
      BAD_POLICY+=("${app}=(selfHeal=${SELF_HEAL:-<empty>},prune=${PRUNE:-<empty>})")
    fi
  done
  if [ "${#BAD_POLICY[@]}" -eq 0 ]; then
    check "sync policy: every Application has selfHeal and prune enabled (${APP_NAMES})" 0
  else
    check "sync policy: every Application has selfHeal and prune enabled" 1 "$(printf '%s; ' "${BAD_POLICY[@]}")"
  fi
fi

# ---------------------------------------------------------------------------
# 5. Drift-revert drill (CD-02) — the one write this script performs.
#
# Scale the live media Deployment away from its git-declared replica count,
# then poll until ArgoCD's selfHeal reverts it. A trap restores the
# resource directly (not via ArgoCD, which is what's under test) if this
# script exits before the drill completes, so a killed run never leaves
# the cluster drifted.
# ---------------------------------------------------------------------------
GIT_REPLICAS=""
if [ -f "${GITOPS_RENDERED_FILE}" ]; then
  # The rendered file is plain multi-document YAML (D-28) — grep the
  # `replicas:` line under the Deployment document. There is exactly one
  # Deployment in this rendered file today (media); this intentionally
  # takes the first match rather than assuming a specific line number.
  GIT_REPLICAS="$(grep -m1 '^\s*replicas:' "${GITOPS_RENDERED_FILE}" 2>/dev/null | grep -oE '[0-9]+')"
fi

DRIFT_RESTORE_DONE=0
drift_restore_trap() {
  if [ "${DRIFT_RESTORE_DONE}" -eq 0 ] && [ -n "${GIT_REPLICAS}" ]; then
    kubectl --context "${APP_CTX}" -n "${DEV_NS}" scale deploy/media --replicas="${GIT_REPLICAS}" >/dev/null 2>&1 || true
  fi
}
trap drift_restore_trap EXIT

if [ -z "${GIT_REPLICAS}" ]; then
  check "drift-revert drill: scale media away from git, confirm ArgoCD reverts it" 1 \
    "could not read a replicas value from ${GITOPS_RENDERED_FILE} — has Plan 03-01 Task 2 run its render pipeline?"
else
  DRIFTED_REPLICAS=$((GIT_REPLICAS + 1))
  DRIFT_START_EPOCH="$(date +%s)"
  DRIFT_START_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  if kubectl --context "${APP_CTX}" -n "${DEV_NS}" scale deploy/media --replicas="${DRIFTED_REPLICAS}" >/dev/null 2>&1; then
    REVERTED=1
    ELAPSED=0
    for _ in $(seq 1 "${DRIFT_TIMEOUT_SECONDS}"); do
      CURRENT_REPLICAS="$(kubectl --context "${APP_CTX}" -n "${DEV_NS}" get deploy media -o jsonpath='{.spec.replicas}' 2>/dev/null)" || CURRENT_REPLICAS=""
      if [ "${CURRENT_REPLICAS}" = "${GIT_REPLICAS}" ]; then
        REVERTED=0
        break
      fi
      sleep 1
    done
    DRIFT_END_EPOCH="$(date +%s)"
    ELAPSED=$((DRIFT_END_EPOCH - DRIFT_START_EPOCH))
    DRIFT_RESTORE_DONE=1

    if [ "${REVERTED}" -eq 0 ]; then
      check "drift-revert drill: media scaled ${GIT_REPLICAS} -> ${DRIFTED_REPLICAS}, ArgoCD reverted it in ${ELAPSED}s (start ${DRIFT_START_ISO})" 0
    else
      check "drift-revert drill: media scaled ${GIT_REPLICAS} -> ${DRIFTED_REPLICAS}, ArgoCD did not revert within ${DRIFT_TIMEOUT_SECONDS}s" 1 \
        "last observed replicas=${CURRENT_REPLICAS:-<empty>}, expected ${GIT_REPLICAS} (start ${DRIFT_START_ISO})"
      # Not reverted by ArgoCD within the bound -- restore directly so the
      # cluster isn't left drifted just because this assertion failed.
      kubectl --context "${APP_CTX}" -n "${DEV_NS}" scale deploy/media --replicas="${GIT_REPLICAS}" >/dev/null 2>&1 || true
    fi
  else
    DRIFT_RESTORE_DONE=1
    check "drift-revert drill: media scaled ${GIT_REPLICAS} -> ${DRIFTED_REPLICAS}, ArgoCD reverted it" 1 \
      "the drift-introducing \`kubectl scale\` command itself failed"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
printf '[verify-argocd] %s passed, %s failed, %s total.\n' \
  "${PASS_COUNT}" "${FAIL_COUNT}" "$((PASS_COUNT + FAIL_COUNT))"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
