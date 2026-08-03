#!/usr/bin/env bash
# verify-clusters.sh — dual-cluster and registry assertions (Plan 02, Task 2;
# FOUND-01/FOUND-03). Sibling of verify-skeleton.sh, following the same
# per-check independently-reported PASS/FAIL convention; scripts/verify.sh
# (the dispatcher) discovers this file by glob — never edited itself.
#
# Deliberately not using `set -e`, same rationale as verify-skeleton.sh:
# every fallible command is captured into a variable first so one failing
# check never aborts the ones after it.

set -uo pipefail

APP_KCTX="k3d-app"
PLATFORM_KCTX="k3d-platform"
APP_KC=(kubectl --context "${APP_KCTX}")
PLATFORM_KC=(kubectl --context "${PLATFORM_KCTX}")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
# 1. Platform cluster: exactly 3 nodes, all Ready
# ---------------------------------------------------------------------------
if kubectl config get-contexts -o name 2>/dev/null | grep -qx "${PLATFORM_KCTX}"; then
  NODE_LINES="$("${PLATFORM_KC[@]}" get nodes --no-headers 2>/dev/null)" || NODE_LINES=""
  TOTAL_NODES="$(printf '%s\n' "${NODE_LINES}" | grep -c . || true)"
  READY_NODES="$(printf '%s\n' "${NODE_LINES}" | awk '$2=="Ready"' | grep -c . || true)"
  if [ "${TOTAL_NODES}" = "3" ] && [ "${READY_NODES}" = "3" ]; then
    check "platform cluster (${PLATFORM_KCTX}) has exactly 3 nodes, all Ready" 0
  else
    check "platform cluster (${PLATFORM_KCTX}) has exactly 3 nodes, all Ready" 1 \
      "total=${TOTAL_NODES} ready=${READY_NODES}"
  fi
else
  check "platform cluster (${PLATFORM_KCTX}) has exactly 3 nodes, all Ready" 1 \
    "kube-context '${PLATFORM_KCTX}' not found in kubeconfig"
fi

# ---------------------------------------------------------------------------
# 2. Platform cluster: exactly 1 node tainted CriticalAddonsOnly:NoExecute
# ---------------------------------------------------------------------------
TAINT_RAW="$("${PLATFORM_KC[@]}" get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.taints}{"\n"}{end}' 2>/dev/null)" || TAINT_RAW=""
TOTAL_TAINT_LINES="$(printf '%s\n' "${TAINT_RAW}" | grep -c . || true)"
TAINTED_COUNT="$(printf '%s\n' "${TAINT_RAW}" | grep -c 'CriticalAddonsOnly.*NoExecute\|NoExecute.*CriticalAddonsOnly' || true)"
UNTAINTED_COUNT="$(printf '%s\n' "${TAINT_RAW}" | awk -F'\t' '{ if ($2 == "") print }' | grep -c . || true)"
if [ "${TOTAL_TAINT_LINES}" = "3" ] && [ "${TAINTED_COUNT}" = "1" ] && [ "${UNTAINTED_COUNT}" = "2" ]; then
  check "platform cluster: exactly 1 node tainted CriticalAddonsOnly:NoExecute, 2 untainted" 0
else
  check "platform cluster: exactly 1 node tainted CriticalAddonsOnly:NoExecute, 2 untainted" 1 \
    "nodes=${TOTAL_TAINT_LINES} tainted=${TAINTED_COUNT} untainted=${UNTAINTED_COUNT} raw=[$(printf '%s' "${TAINT_RAW}" | tr '\n' ';')]"
fi

# ---------------------------------------------------------------------------
# 3. Both clusters simultaneously running (k3d cluster list)
# ---------------------------------------------------------------------------
CLUSTER_LIST="$(k3d cluster list --no-headers 2>/dev/null)" || CLUSTER_LIST=""
APP_RUNNING="$(printf '%s\n' "${CLUSTER_LIST}" | awk '$1=="app"{print $2, $3}')"
PLATFORM_RUNNING="$(printf '%s\n' "${CLUSTER_LIST}" | awk '$1=="platform"{print $2, $3}')"
if [ "${APP_RUNNING}" = "1/1 3/3" ] && [ "${PLATFORM_RUNNING}" = "1/1 2/2" ]; then
  check "both clusters simultaneously running (app 1/1+3/3, platform 1/1+2/2)" 0
else
  check "both clusters simultaneously running (app 1/1+3/3, platform 1/1+2/2)" 1 \
    "app=[${APP_RUNNING}] platform=[${PLATFORM_RUNNING}]"
fi

# ---------------------------------------------------------------------------
# 4. https://hello.platform.athena.net returns 200 with a verified chain
# ---------------------------------------------------------------------------
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' https://hello.platform.athena.net 2>/dev/null)"
HTTP_CODE="${HTTP_CODE:-000}"
SSL_VERIFY_RESULT="$(curl -sS -o /dev/null -w '%{ssl_verify_result}' https://hello.platform.athena.net 2>/dev/null)"
SSL_VERIFY_RESULT="${SSL_VERIFY_RESULT:-1}"
if [ "${HTTP_CODE}" = "200" ] && [ "${SSL_VERIFY_RESULT}" = "0" ]; then
  check "https://hello.platform.athena.net -> 200, ssl_verify_result 0 (no -k)" 0
else
  check "https://hello.platform.athena.net -> 200, ssl_verify_result 0 (no -k)" 1 \
    "http_code=[${HTTP_CODE}] ssl_verify_result=[${SSL_VERIFY_RESULT}]"
fi

# ---------------------------------------------------------------------------
# 5. https://hello.athena.net (app cluster) still serves 200 — the second
#    binding did not disturb the first
# ---------------------------------------------------------------------------
APP_HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' https://hello.athena.net 2>/dev/null)"
APP_HTTP_CODE="${APP_HTTP_CODE:-000}"
if [ "${APP_HTTP_CODE}" = "200" ]; then
  check "https://hello.athena.net still -> 200 (app cluster undisturbed)" 0
else
  check "https://hello.athena.net still -> 200 (app cluster undisturbed)" 1 \
    "http_code=[${APP_HTTP_CODE}]"
fi

# ---------------------------------------------------------------------------
# 6. App cluster has exactly the three environment namespaces; platform
#    cluster has none of them
# ---------------------------------------------------------------------------
APP_NS_COUNT="$("${APP_KC[@]}" get ns dev stg prod -o name 2>/dev/null | grep -c . || true)"
PLATFORM_HAS_ENV_NS=0
for ns in dev stg prod; do
  if "${PLATFORM_KC[@]}" get ns "${ns}" >/dev/null 2>&1; then
    PLATFORM_HAS_ENV_NS=1
  fi
done
if [ "${APP_NS_COUNT}" = "3" ] && [ "${PLATFORM_HAS_ENV_NS}" = "0" ]; then
  check "app cluster has dev/stg/prod namespaces; platform cluster has none" 0
else
  check "app cluster has dev/stg/prod namespaces; platform cluster has none" 1 \
    "app_ns_count=${APP_NS_COUNT} platform_has_env_ns=${PLATFORM_HAS_ENV_NS}"
fi

# ---------------------------------------------------------------------------
# 7. registry-smoke.sh exits 0
# ---------------------------------------------------------------------------
if bash "${SCRIPT_DIR}/registry-smoke.sh" >/tmp/registry-smoke-verify.log 2>&1; then
  check "registry-smoke.sh exits 0 (registry serves both clusters and host)" 0
else
  check "registry-smoke.sh exits 0 (registry serves both clusters and host)" 1 \
    "see /tmp/registry-smoke-verify.log; tail: $(tail -3 /tmp/registry-smoke-verify.log | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
printf '[verify-clusters] %s passed, %s failed, %s total.\n' \
  "${PASS_COUNT}" "${FAIL_COUNT}" "$((PASS_COUNT + FAIL_COUNT))"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
