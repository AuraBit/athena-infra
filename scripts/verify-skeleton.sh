#!/usr/bin/env bash
# verify-skeleton.sh — FOUND-01 (app cluster) and FOUND-04 (athena.net domain
# fiction) assertions for the walking skeleton (Plan 01, Task 3).
#
# Each check is independently reported with its own PASS/FAIL line and, on
# failure, the observed value that made it fail — so a failing run is
# diagnosable without re-running anything by hand. Deliberately not using
# `set -e`: every fallible command below is captured into a variable first
# so one failing check never aborts the ones after it; scripts/verify.sh
# (the dispatcher this script is a sibling of) is what turns any FAIL here
# into a non-zero process exit.
#
# Targets: estate/athena-infra/clusters/app/gateway.yaml and
# clusters/app/smoke/hello-echo.yaml (object names/namespaces asserted here
# come directly from those manifests).

set -uo pipefail

KCTX="k3d-app"
KC=(kubectl --context "${KCTX}")

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
# 1. k3d-app context exists; cluster reports exactly 4 nodes, all Ready
# ---------------------------------------------------------------------------
if kubectl config get-contexts -o name 2>/dev/null | grep -qx "${KCTX}"; then
  NODE_LINES="$("${KC[@]}" get nodes --no-headers 2>/dev/null)" || NODE_LINES=""
  TOTAL_NODES="$(printf '%s\n' "${NODE_LINES}" | grep -c . || true)"
  READY_NODES="$(printf '%s\n' "${NODE_LINES}" | awk '$2=="Ready"' | grep -c . || true)"
  if [ "${TOTAL_NODES}" = "4" ] && [ "${READY_NODES}" = "4" ]; then
    check "app cluster (${KCTX}) has exactly 4 nodes, all Ready" 0
  else
    check "app cluster (${KCTX}) has exactly 4 nodes, all Ready" 1 \
      "total=${TOTAL_NODES} ready=${READY_NODES}"
  fi
else
  check "app cluster (${KCTX}) has exactly 4 nodes, all Ready" 1 \
    "kube-context '${KCTX}' not found in kubeconfig"
fi

# ---------------------------------------------------------------------------
# 2. Exactly one node carries the CriticalAddonsOnly NoExecute taint; the
#    other three carry none
# ---------------------------------------------------------------------------
TAINT_RAW="$("${KC[@]}" get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.taints}{"\n"}{end}' 2>/dev/null)" || TAINT_RAW=""
TOTAL_TAINT_LINES="$(printf '%s\n' "${TAINT_RAW}" | grep -c . || true)"
TAINTED_COUNT="$(printf '%s\n' "${TAINT_RAW}" | grep -c 'CriticalAddonsOnly.*NoExecute\|NoExecute.*CriticalAddonsOnly' || true)"
UNTAINTED_COUNT="$(printf '%s\n' "${TAINT_RAW}" | awk -F'\t' '{ if ($2 == "") print }' | grep -c . || true)"
if [ "${TOTAL_TAINT_LINES}" = "4" ] && [ "${TAINTED_COUNT}" = "1" ] && [ "${UNTAINTED_COUNT}" = "3" ]; then
  check "exactly 1 node tainted CriticalAddonsOnly:NoExecute, 3 untainted" 0
else
  check "exactly 1 node tainted CriticalAddonsOnly:NoExecute, 3 untainted" 1 \
    "nodes=${TOTAL_TAINT_LINES} tainted=${TAINTED_COUNT} untainted=${UNTAINTED_COUNT} raw=[$(printf '%s' "${TAINT_RAW}" | tr '\n' ';')]"
fi

# ---------------------------------------------------------------------------
# 3. No pod for the k3s bundled ingress controller (Traefik) in kube-system
# ---------------------------------------------------------------------------
TRAEFIK_PODS="$("${KC[@]}" -n kube-system get pods -o name 2>/dev/null | grep -i traefik || true)"
if [ -z "${TRAEFIK_PODS}" ]; then
  check "no Traefik pod in kube-system (bundled ingress disabled, D-11)" 0
else
  check "no Traefik pod in kube-system (bundled ingress disabled, D-11)" 1 \
    "found: $(printf '%s' "${TRAEFIK_PODS}" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# 4. k3d-managed registry container is running and its host port answers
# ---------------------------------------------------------------------------
REGISTRY_STATUS="$(docker ps --filter 'name=^/athena-registry$' --format '{{.Status}}' 2>/dev/null || true)"
REGISTRY_HTTP="$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:5000/v2/ 2>/dev/null)"
REGISTRY_HTTP="${REGISTRY_HTTP:-000}"
if [[ "${REGISTRY_STATUS}" == Up* ]] && [ "${REGISTRY_HTTP}" = "200" ]; then
  check "athena-registry container running, port 5000 answers" 0
else
  check "athena-registry container running, port 5000 answers" 1 \
    "docker_status=[${REGISTRY_STATUS}] http_code=[${REGISTRY_HTTP}]"
fi

# ---------------------------------------------------------------------------
# 5. Wildcard DNS: two arbitrary app-domain subdomains resolve to 127.0.0.1,
#    one platform-domain subdomain resolves to 127.0.0.2 (proves wildcard,
#    not a per-host hosts-file entry)
# ---------------------------------------------------------------------------
DNS_APP_A="$(getent hosts verify-check-a.athena.net 2>/dev/null | awk '{print $1}')"
DNS_APP_B="$(getent hosts verify-check-b.athena.net 2>/dev/null | awk '{print $1}')"
DNS_PLATFORM="$(getent hosts verify-check-c.platform.athena.net 2>/dev/null | awk '{print $1}')"
if [ "${DNS_APP_A}" = "127.0.0.1" ] && [ "${DNS_APP_B}" = "127.0.0.1" ] && [ "${DNS_PLATFORM}" = "127.0.0.2" ]; then
  check "wildcard DNS: *.athena.net->127.0.0.1, *.platform.athena.net->127.0.0.2" 0
else
  check "wildcard DNS: *.athena.net->127.0.0.1, *.platform.athena.net->127.0.0.2" 1 \
    "app_a=[${DNS_APP_A}] app_b=[${DNS_APP_B}] platform=[${DNS_PLATFORM}]"
fi

# ---------------------------------------------------------------------------
# 6. athena-net-wildcard Certificate is Ready and the athena Gateway is
#    Programmed
# ---------------------------------------------------------------------------
CERT_READY="$("${KC[@]}" -n gateway get certificate athena-net-wildcard -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" || CERT_READY=""
GW_PROGRAMMED="$("${KC[@]}" -n gateway get gateway athena -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)" || GW_PROGRAMMED=""
if [ "${CERT_READY}" = "True" ] && [ "${GW_PROGRAMMED}" = "True" ]; then
  check "Certificate/athena-net-wildcard Ready, Gateway/athena Programmed" 0
else
  check "Certificate/athena-net-wildcard Ready, Gateway/athena Programmed" 1 \
    "certificate_ready=[${CERT_READY}] gateway_programmed=[${GW_PROGRAMMED}]"
fi

# ---------------------------------------------------------------------------
# 7. https://hello.athena.net returns 200 with ssl_verify_result 0, no -k
# ---------------------------------------------------------------------------
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' https://hello.athena.net 2>/dev/null)"
HTTP_CODE="${HTTP_CODE:-000}"
SSL_VERIFY_RESULT="$(curl -sS -o /dev/null -w '%{ssl_verify_result}' https://hello.athena.net 2>/dev/null)"
SSL_VERIFY_RESULT="${SSL_VERIFY_RESULT:-1}"
if [ "${HTTP_CODE}" = "200" ] && [ "${SSL_VERIFY_RESULT}" = "0" ]; then
  check "https://hello.athena.net -> 200, ssl_verify_result 0 (no -k)" 0
else
  check "https://hello.athena.net -> 200, ssl_verify_result 0 (no -k)" 1 \
    "http_code=[${HTTP_CODE}] ssl_verify_result=[${SSL_VERIFY_RESULT}]"
fi

# ---------------------------------------------------------------------------
# 8. Served certificate's issuer matches the local mkcert root CA's subject,
#    read from `mkcert -CAROOT` at runtime (never hardcoded)
# ---------------------------------------------------------------------------
CAROOT="$(mkcert -CAROOT 2>/dev/null)" || CAROOT=""
if [ -n "${CAROOT}" ] && [ -f "${CAROOT}/rootCA.pem" ]; then
  EXPECTED_SUBJECT="$(openssl x509 -in "${CAROOT}/rootCA.pem" -noout -subject 2>/dev/null | sed 's/^subject=//')"
  SERVED_ISSUER="$(openssl s_client -connect hello.athena.net:443 -servername hello.athena.net </dev/null 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
  if [ -n "${EXPECTED_SUBJECT}" ] && [ "${SERVED_ISSUER}" = "${EXPECTED_SUBJECT}" ]; then
    check "served cert issuer matches mkcert root CA subject (from mkcert -CAROOT)" 0
  else
    check "served cert issuer matches mkcert root CA subject (from mkcert -CAROOT)" 1 \
      "expected=[${EXPECTED_SUBJECT}] served=[${SERVED_ISSUER}]"
  fi
else
  check "served cert issuer matches mkcert root CA subject (from mkcert -CAROOT)" 1 \
    "mkcert -CAROOT did not resolve to a directory containing rootCA.pem (CAROOT=[${CAROOT}])"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
printf '[verify-skeleton] %s passed, %s failed, %s total.\n' \
  "${PASS_COUNT}" "${FAIL_COUNT}" "$((PASS_COUNT + FAIL_COUNT))"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
