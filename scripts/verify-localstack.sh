#!/usr/bin/env bash
# verify-localstack.sh — FOUND-02 assertions for the LocalStack host service
# (Plan 03, Task 2).
#
# A health endpoint returning 200 is not proof LocalStack does real work —
# RESEARCH.md's Pitfall 4 and this plan's threat model (T-01-13) describe
# exactly the failure mode where health answers and every real service call
# fails (or, worse, claims a paid-tier service is "available" when it is
# license-gated). This script proves real work, from both of D-15's
# reachability paths, and machine-checks the coverage table against what the
# running emulator actually offers rather than what it optimistically
# reports.
#
# Deliberately not using `set -e` (mirrors verify-skeleton.sh): every
# fallible command is captured into a variable first so one failing check
# never aborts the ones after it; scripts/verify.sh (this script's
# dispatcher) is what turns any FAIL here into a non-zero process exit.
#
# The script hardcodes no auth token and reads no value out of
# .localstack.env — every check here talks to the already-running LocalStack
# over its public health/API surface, which needs no token itself.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COVERAGE_FILE="${SCRIPT_DIR}/../docs/localstack-service-coverage.md"
LS_ENDPOINT="http://localhost:4566"
KCTX="k3d-app"
KC=(kubectl --context "${KCTX}")
SMOKE_BUCKET="athena-localstack-smoke"
SCRATCH_NS="localstack-smoke"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

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

aws_ls() { aws --endpoint-url "${LS_ENDPOINT}" "$@" 2>&1; }

cleanup() {
  aws_ls s3 rb "s3://${SMOKE_BUCKET}" --force >/dev/null 2>&1 || true
  "${KC[@]}" delete namespace "${SCRATCH_NS}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. The localstack systemd unit is enabled and active
# ---------------------------------------------------------------------------
UNIT_ENABLED="$(systemctl is-enabled localstack 2>/dev/null)" || UNIT_ENABLED="unknown"
UNIT_ACTIVE="$(systemctl is-active localstack 2>/dev/null)" || UNIT_ACTIVE="unknown"
if [ "${UNIT_ENABLED}" = "enabled" ] && [ "${UNIT_ACTIVE}" = "active" ]; then
  check "localstack systemd unit is enabled and active" 0
else
  check "localstack systemd unit is enabled and active" 1 \
    "enabled=[${UNIT_ENABLED}] active=[${UNIT_ACTIVE}]"
fi

# ---------------------------------------------------------------------------
# 2. Health endpoint returns a body whose services map is non-empty. Retries
#    briefly: a just-(re)started LocalStack container reports systemd-active
#    and even answers the socket before its own app has finished booting
#    (observed live after `systemctl restart localstack` — first curl
#    returned an empty body, a few seconds later it returned the full
#    services map), so a single immediate curl here would be racy.
# ---------------------------------------------------------------------------
HEALTH_BODY=""
HEALTH_SERVICE_COUNT="0"
for _ in $(seq 1 12); do
  HEALTH_BODY="$(curl -sS "${LS_ENDPOINT}/_localstack/health" 2>/dev/null)" || HEALTH_BODY=""
  HEALTH_SERVICE_COUNT="$(printf '%s' "${HEALTH_BODY}" | jq -r '.services // {} | length' 2>/dev/null)" || HEALTH_SERVICE_COUNT="0"
  if [ -n "${HEALTH_BODY}" ] && [ "${HEALTH_SERVICE_COUNT}" -gt 0 ] 2>/dev/null; then
    break
  fi
  sleep 5
done
if [ -n "${HEALTH_BODY}" ] && [ "${HEALTH_SERVICE_COUNT}" -gt 0 ] 2>/dev/null; then
  check "health endpoint returns a non-empty services map (${HEALTH_SERVICE_COUNT} services)" 0
else
  check "health endpoint returns a non-empty services map" 1 \
    "body=[${HEALTH_BODY:0:200}]"
fi

# ---------------------------------------------------------------------------
# 3. Real work from the host: S3 create/put/get/delete round trip
# ---------------------------------------------------------------------------
AWSLOCAL_BIN=""
if command -v awslocal >/dev/null 2>&1; then
  AWSLOCAL_BIN="awslocal"
fi

s3_cmd() {
  if [ -n "${AWSLOCAL_BIN}" ]; then
    "${AWSLOCAL_BIN}" "$@" 2>&1
  else
    aws_ls "$@"
  fi
}

S3_OBJECT_KEY="probe.txt"
S3_OBJECT_BODY="athena-localstack-smoke-$(date +%s)-$$"
S3_TMP_UPLOAD="$(mktemp)"
S3_TMP_DOWNLOAD="$(mktemp)"
printf '%s' "${S3_OBJECT_BODY}" > "${S3_TMP_UPLOAD}"

S3_ROUNDTRIP_OK=1
S3_OBSERVED=""

if s3_cmd s3 mb "s3://${SMOKE_BUCKET}" >/dev/null 2>&1 \
  && s3_cmd s3 cp "${S3_TMP_UPLOAD}" "s3://${SMOKE_BUCKET}/${S3_OBJECT_KEY}" >/dev/null 2>&1 \
  && s3_cmd s3 cp "s3://${SMOKE_BUCKET}/${S3_OBJECT_KEY}" "${S3_TMP_DOWNLOAD}" >/dev/null 2>&1; then
  RETRIEVED_BODY="$(cat "${S3_TMP_DOWNLOAD}" 2>/dev/null)"
  if [ "${RETRIEVED_BODY}" = "${S3_OBJECT_BODY}" ]; then
    S3_ROUNDTRIP_OK=0
  else
    S3_OBSERVED="written=[${S3_OBJECT_BODY}] retrieved=[${RETRIEVED_BODY}]"
  fi
else
  S3_OBSERVED="bucket create/put/get failed (see s3_cmd output above)"
fi

s3_cmd s3 rm "s3://${SMOKE_BUCKET}/${S3_OBJECT_KEY}" >/dev/null 2>&1 || true
s3_cmd s3 rb "s3://${SMOKE_BUCKET}" --force >/dev/null 2>&1 || true
rm -f "${S3_TMP_UPLOAD}" "${S3_TMP_DOWNLOAD}"

check "S3 create/put/get/delete round trip: retrieved body matches written body" "${S3_ROUNDTRIP_OK}" "${S3_OBSERVED}"

# ---------------------------------------------------------------------------
# 4. Real work from inside a cluster: a pod on k3d-app reaches LocalStack at
#    host.k3d.internal:4566 — the in-cluster hostname, distinct from the
#    host-side localhost:4566 (D-15's reachability split)
# ---------------------------------------------------------------------------
INCLUSTER_OK=1
INCLUSTER_OBSERVED=""

if kubectl config get-contexts -o name 2>/dev/null | grep -qx "${KCTX}"; then
  "${KC[@]}" delete namespace "${SCRATCH_NS}" --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
  "${KC[@]}" create namespace "${SCRATCH_NS}" >/dev/null 2>&1

  cat <<PODSPEC | "${KC[@]}" -n "${SCRATCH_NS}" apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: localstack-smoke
  namespace: ${SCRATCH_NS}
spec:
  restartPolicy: Never
  containers:
    - name: localstack-smoke
      image: curlimages/curl:8.11.1
      args:
        - -sS
        - -o
        - /dev/null
        - -w
        - "%{http_code}"
        - http://host.k3d.internal:4566/_localstack/health
PODSPEC

  if "${KC[@]}" -n "${SCRATCH_NS}" wait --timeout=90s pod/localstack-smoke \
      --for=jsonpath='{.status.phase}'=Succeeded >/dev/null 2>&1; then
    POD_LOGS="$("${KC[@]}" -n "${SCRATCH_NS}" logs pod/localstack-smoke 2>/dev/null || true)"
    if [[ "${POD_LOGS}" == *"200"* ]]; then
      INCLUSTER_OK=0
    else
      INCLUSTER_OBSERVED="pod logs (expected http_code 200): ${POD_LOGS}"
    fi
  else
    INCLUSTER_OBSERVED="pod did not reach Succeeded within timeout"
    "${KC[@]}" -n "${SCRATCH_NS}" describe pod localstack-smoke >/dev/null 2>&1 || true
  fi

  "${KC[@]}" delete namespace "${SCRATCH_NS}" --wait=true >/dev/null 2>&1 || true
else
  INCLUSTER_OBSERVED="kube-context '${KCTX}' not found in kubeconfig"
fi

check "in-cluster pod reaches LocalStack at host.k3d.internal:4566" "${INCLUSTER_OK}" "${INCLUSTER_OBSERVED}"

# ---------------------------------------------------------------------------
# 5. Coverage-table contract: docs/localstack-service-coverage.md must not
#    claim more than the running emulator actually offers. For every row
#    whose verification mode is `emulated`, its service name must appear as
#    a key in the health endpoint's services map. For every row whose mode
#    is `code+docs-only`, its divergence-note cell must be non-empty.
# ---------------------------------------------------------------------------
COVERAGE_OK=1
COVERAGE_OBSERVED=""

if [ ! -f "${COVERAGE_FILE}" ]; then
  COVERAGE_OBSERVED="coverage file not found: ${COVERAGE_FILE}"
else
  BAD_ROWS=()
  while IFS='|' read -r _blank svc consumer tier mode note _trailer; do
    svc="$(printf '%s' "${svc}" | xargs 2>/dev/null || true)"
    mode="$(printf '%s' "${mode}" | xargs 2>/dev/null || true)"
    note="$(printf '%s' "${note}" | xargs 2>/dev/null || true)"

    [ -z "${svc}" ] && continue
    case "${svc}" in
      Service|-*|:-*) continue ;;
    esac

    case "${mode}" in
      emulated)
        SVC_PRESENT="$(printf '%s' "${HEALTH_BODY}" | jq -r --arg svc "${svc}" '(.services // {}) | has($svc)' 2>/dev/null)"
        if [ "${SVC_PRESENT}" != "true" ]; then
          BAD_ROWS+=("${svc} (claims emulated but is not a key in the live health services map)")
        fi
        ;;
      code+docs-only)
        case "${note}" in
          ""|"-"|"—")
            BAD_ROWS+=("${svc} (mode=code+docs-only but divergence note is empty)")
            ;;
        esac
        ;;
      *)
        BAD_ROWS+=("${svc} (unrecognized verification mode: '${mode}')")
        ;;
    esac
  done < <(grep '^|' "${COVERAGE_FILE}")

  if [ "${#BAD_ROWS[@]}" -eq 0 ]; then
    COVERAGE_OK=0
  else
    COVERAGE_OBSERVED="$(printf '%s; ' "${BAD_ROWS[@]}")"
  fi
fi

check "coverage table (docs/localstack-service-coverage.md) matches the live health map" "${COVERAGE_OK}" "${COVERAGE_OBSERVED}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
printf '[verify-localstack] %s passed, %s failed, %s total.\n' \
  "${PASS_COUNT}" "${FAIL_COUNT}" "$((PASS_COUNT + FAIL_COUNT))"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
