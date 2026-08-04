#!/usr/bin/env bash
# fake-success-drill.sh — proves, live, that verify-network.sh (IAC-04)
# genuinely catches a resource deleted behind Terraform's back, rather than
# describing that it should (Plan 02-10, Task 2).
#
# The failure mode IAC-04 exists to guard against is LocalStack reporting an
# apply as successful while the resource it claims to have created is not
# really there — this project has already live-verified that exact trap for
# four license-gated services (docs/localstack-service-coverage.md:
# rds/elasticache/cloudfront/eks). Those services are out of scope on this
# account, so this drill induces the equivalent divergence directly: delete
# a real resource through the AWS CLI, bypassing Terraform entirely, so
# state and outputs still name a resource the emulated account no longer
# holds.
#
# One empirically-important fact this script's design depends on (found
# while building it, recorded in docs/drills/fake-success-verification.md):
# Terraform's own `plan` DOES refresh and detect a directly-deleted EC2/S3
# resource — an ordinary `terraform apply` run against a diverged
# environment just heals it. That means the CI proof (Phase 3 below) cannot
# simply dispatch a normal apply and expect it to stay broken; the
# divergence has to be introduced AFTER that run's `terraform plan` step has
# already computed and saved its plan file (which reflects the
# still-converged pre-divergence state), so `terraform apply tfplan` neither
# touches nor re-examines the now-deleted resource and reports genuine
# success, while `verify-network.sh` — which makes its own independent
# describe calls, never trusting the saved plan — catches the divergence a
# few seconds later in the same job.
#
# Four phases, run against `dev` (the environment Plan 02-09's own
# drill-only `workflow_dispatch` input already targets, and the one with no
# Environment protection rules, so this drill needs no approval step):
#   1. Precondition: dev starts green.
#   2. Variant 1 (a resource verify-network.sh DOES assert on — the
#      flow-logs bucket): delete it, assert the verifier goes red and names
#      it, restore, assert green again.
#   3. Variant 2 (a resource verify-network.sh did NOT originally assert on
#      — the public route table's default route): this drill's own live run
#      (recorded in docs/drills/fake-success-verification.md) is what FOUND
#      that gap; the assertion this script runs below proves the fix
#      (verify-network.sh's new public_route_table_id check, added in
#      response) now closes it, and stays closed on every future run of this
#      script.
#   4. The CI proof: dispatch terraform-core-network.yml's `workflow_dispatch`
#      path for dev (Plan 02-09's drill_env input), delete the flow-logs
#      bucket the instant the run's own "terraform plan" step reports done,
#      and confirm the run's "terraform apply" step is green while
#      "verify-network.sh" and the job itself are red.
#
# Preconditions: `gh` authenticated against AuraBit/athena-infra with
# `workflow` scope (Phase 3 dispatches a real run); AWS_* env vars NOT
# pre-exported (this script manages dev's credentials itself via
# scripts/tf-env.sh, sourced fresh for every phase); dev genuinely converged
# and green before this script starts (Phase 1 asserts this and refuses to
# proceed otherwise — a drill starting from an unknown state proves
# nothing).
#
# Usage: bash scripts/drills/fake-success-drill.sh
#   (repeatable — every invocation deletes and restores real resources
#   against dev, and Phase 4 dispatches a fresh, real Actions run; like
#   concurrency-queue-drill.sh, not part of scripts/verify.sh's
#   auto-discovered verify-*.sh suite for exactly that reason.)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO="AuraBit/athena-infra"
WORKFLOW="terraform-core-network.yml"
ENV_DIR="${REPO_ROOT}/envs/dev/core-network"
LS_ENDPOINT="http://localhost:4566"

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

info() { printf '[drill] %s\n' "$1"; }
ts()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
run_url() { printf 'https://github.com/%s/actions/runs/%s' "${REPO}" "$1"; }

dev_creds() {
  export AWS_ACCESS_KEY_ID="111111111111"
  export AWS_SECRET_ACCESS_KEY="111111111111"
  export AWS_DEFAULT_REGION="us-east-1"
}

aws_ls() { aws --endpoint-url "${LS_ENDPOINT}" "$@" 2>&1; }

# verify-network.sh's check() prints PASS/FAIL wrapped in ANSI color codes
# (\033[31m...\033[0m) -- a literal grep -F "FAIL  dev: ..." against its raw
# output never matches, because the reset sequence sits between "FAIL" and
# the two spaces the pattern expects. Strip ANSI escapes before any
# string-matching assertion against captured verify-network.sh output.
strip_ansi() { sed -E 's/\x1b\[[0-9;]*m//g'; }

tf() { ( cd "${ENV_DIR}" && dev_creds && terraform "$@" ); }

restore_dev() {
  info "restoring dev via terraform apply..."
  tf apply -input=false -auto-approve -no-color >/tmp/fake-success-drill-restore.log 2>&1
  local rc=$?
  return "${rc}"
}

EVIDENCE_LOG="$(mktemp)"
log_evidence() { printf '%s\n' "$1" | tee -a "${EVIDENCE_LOG}"; }

echo "=== Plan 02-10 fake-success-verification drill — $(ts) ==="
echo "repo: ${REPO}  workflow: ${WORKFLOW}  target env: dev"
echo

# ---------------------------------------------------------------------------
# Phase 0 — precondition: dev starts green. A drill starting from an unknown
# state proves nothing (same discipline concurrency-queue-drill.sh and
# stale-lock-recovery follow).
# ---------------------------------------------------------------------------
log_evidence "## Phase 0 — precondition: dev starts green"
bash "${REPO_ROOT}/scripts/verify-network.sh" dev >/tmp/fake-success-drill-precondition.log 2>&1
PRECONDITION_RC=$?
check "phase 0: verify-network.sh dev exits 0 before this drill touches anything" "${PRECONDITION_RC}" \
  "$(tail -3 /tmp/fake-success-drill-precondition.log)"
if [ "${PRECONDITION_RC}" -ne 0 ]; then
  echo "FATAL: dev is not green — refusing to run a drill against an already-diverged environment." >&2
  cat "${EVIDENCE_LOG}"
  rm -f "${EVIDENCE_LOG}"
  exit 1
fi
echo

# ---------------------------------------------------------------------------
# Phase 1 — Variant 1: a resource verify-network.sh DOES assert on
# (the flow-logs bucket). Delete it directly, assert the verifier goes red
# and its FAIL line names the specific missing resource, restore, assert
# green + a clean plan.
# ---------------------------------------------------------------------------
log_evidence "## Phase 1 — Variant 1: flow-logs bucket (an asserted-on resource)"

BEFORE_OUTPUTS="$(tf output -json 2>&1)"
FLOW_BUCKET="$(printf '%s' "${BEFORE_OUTPUTS}" | jq -r '.flow_logs_bucket_name.value // empty' 2>/dev/null)"
log_evidence "recorded flow_logs_bucket_name=${FLOW_BUCKET} from terraform output -json at $(ts)"

if [ -z "${FLOW_BUCKET}" ]; then
  check "phase 1: flow_logs_bucket_name output is present" 1 "terraform output -json has no .flow_logs_bucket_name.value"
else
  dev_creds
  DELETE_OUT="$(aws_ls s3 rb "s3://${FLOW_BUCKET}" --force)"
  log_evidence "deleted s3://${FLOW_BUCKET} directly via aws s3 rb --force at $(ts): ${DELETE_OUT}"

  V1_LOG="$(bash "${REPO_ROOT}/scripts/verify-network.sh" dev 2>&1)"
  V1_RC=$?
  V1_FAIL_LINE="$(printf '%s' "${V1_LOG}" | grep -F "${FLOW_BUCKET}" | grep -i "FAIL" -A1 | head -4)"
  log_evidence "verify-network.sh dev after deletion, exit=${V1_RC}:"
  log_evidence "${V1_FAIL_LINE}"

  V1_OK=0
  [ "${V1_RC}" -ne 0 ] || V1_OK=1
  printf '%s' "${V1_LOG}" | strip_ansi | grep -qF "FAIL  dev: flow-logs bucket ${FLOW_BUCKET} exists" || V1_OK=1

  check "phase 1: verify-network.sh dev goes non-zero and names the deleted bucket (${FLOW_BUCKET}) in its FAIL line" "${V1_OK}" \
    "exit=${V1_RC}; relevant lines: ${V1_FAIL_LINE}"
fi

restore_dev
RESTORE1_RC=$?
V1_RESTORE_LOG="$(bash "${REPO_ROOT}/scripts/verify-network.sh" dev 2>&1)"
V1_RESTORE_RC=$?
PLAN1_OUT="$(tf plan -input=false -detailed-exitcode -no-color 2>&1)"
PLAN1_RC=$?

check "phase 1: restore (terraform apply) succeeded" "${RESTORE1_RC}" "$(tail -5 /tmp/fake-success-drill-restore.log)"
check "phase 1: verify-network.sh dev green again after restore" "${V1_RESTORE_RC}" "$(printf '%s' "${V1_RESTORE_LOG}" | tail -3)"
check "phase 1: terraform plan -detailed-exitcode exits 0 after restore (no drift)" "$([ "${PLAN1_RC}" -eq 0 ] && echo 0 || echo 1)" \
  "exit=${PLAN1_RC}"
echo

# ---------------------------------------------------------------------------
# Phase 2 — Variant 2: a resource verify-network.sh did NOT originally
# assert on (the public route table's default route to the internet
# gateway). This drill's own live run against the PRE-FIX verify-network.sh
# is what found this gap in the first place (recorded, with the exact
# commands and the vacuous-green output, in
# docs/drills/fake-success-verification.md) — the assertion below proves the
# fix added in response (public_route_table_id's own check) now closes it,
# and keeps it closed on every future run.
# ---------------------------------------------------------------------------
log_evidence "## Phase 2 — Variant 2: public route table default route (the coverage gap this drill found)"

BEFORE_OUTPUTS2="$(tf output -json 2>&1)"
PUBLIC_RT_ID="$(printf '%s' "${BEFORE_OUTPUTS2}" | jq -r '.public_route_table_id.value // empty' 2>/dev/null)"
log_evidence "recorded public_route_table_id=${PUBLIC_RT_ID} from terraform output -json at $(ts)"

if [ -z "${PUBLIC_RT_ID}" ]; then
  check "phase 2: public_route_table_id output is present" 1 "terraform output -json has no .public_route_table_id.value"
else
  dev_creds
  DELROUTE_OUT="$(aws_ls ec2 delete-route --route-table-id "${PUBLIC_RT_ID}" --destination-cidr-block 0.0.0.0/0)"
  log_evidence "deleted 0.0.0.0/0 route from ${PUBLIC_RT_ID} directly via aws ec2 delete-route at $(ts): ${DELROUTE_OUT}"

  V2_LOG="$(bash "${REPO_ROOT}/scripts/verify-network.sh" dev 2>&1)"
  V2_RC=$?
  V2_FAIL_LINE="$(printf '%s' "${V2_LOG}" | grep -A1 "FAIL.*public_route_table_id" | head -4)"
  log_evidence "verify-network.sh dev after route deletion, exit=${V2_RC}:"
  log_evidence "${V2_FAIL_LINE}"

  V2_OK=0
  [ "${V2_RC}" -ne 0 ] || V2_OK=1
  printf '%s' "${V2_LOG}" | strip_ansi | grep -q "FAIL  dev: public_route_table_id" || V2_OK=1

  check "phase 2: verify-network.sh dev now catches the public-route deletion (coverage gap closed by the public_route_table_id assertion)" "${V2_OK}" \
    "exit=${V2_RC}; relevant lines: ${V2_FAIL_LINE}"
fi

restore_dev
RESTORE2_RC=$?
V2_RESTORE_LOG="$(bash "${REPO_ROOT}/scripts/verify-network.sh" dev 2>&1)"
V2_RESTORE_RC=$?
PLAN2_OUT="$(tf plan -input=false -detailed-exitcode -no-color 2>&1)"
PLAN2_RC=$?

check "phase 2: restore (terraform apply) succeeded" "${RESTORE2_RC}" "$(tail -5 /tmp/fake-success-drill-restore.log)"
check "phase 2: verify-network.sh dev green again after restore" "${V2_RESTORE_RC}" "$(printf '%s' "${V2_RESTORE_LOG}" | tail -3)"
check "phase 2: terraform plan -detailed-exitcode exits 0 after restore (no drift)" "$([ "${PLAN2_RC}" -eq 0 ] && echo 0 || echo 1)" \
  "exit=${PLAN2_RC}"
echo

# ---------------------------------------------------------------------------
# Phase 3 — the CI proof: dispatch terraform-core-network.yml's
# workflow_dispatch path for dev (Plan 02-09's drill_env input), then delete
# the flow-logs bucket the instant the run's own "terraform plan" step
# reports done. That step's SAVED plan reflects the still-converged
# pre-deletion state (dev has no drift at dispatch time), so
# `terraform apply tfplan` neither touches nor re-examines the bucket and
# reports genuine success — while verify-network.sh, running independent
# describe calls a few seconds later in the SAME job, catches the deletion.
# ---------------------------------------------------------------------------
log_evidence "## Phase 3 — the CI proof: apply (dev) green, job red at verify-network.sh"

BEFORE_RUNS="$(gh api "repos/${REPO}/actions/workflows/${WORKFLOW}/runs?event=workflow_dispatch&per_page=10" --jq '.workflow_runs[].id' 2>/dev/null | sort -n)"
gh workflow run "${WORKFLOW}" --repo "${REPO}" --ref main -f drill_env=dev -f drill_hold_seconds=0 >/dev/null 2>&1

RUN_ID=""
for _ in $(seq 1 40); do
  sleep 1
  AFTER_RUNS="$(gh api "repos/${REPO}/actions/workflows/${WORKFLOW}/runs?event=workflow_dispatch&per_page=10" --jq '.workflow_runs[].id' 2>/dev/null | sort -n)"
  NEW_ID="$(comm -13 <(printf '%s\n' "${BEFORE_RUNS}") <(printf '%s\n' "${AFTER_RUNS}") | tail -1)"
  if [ -n "${NEW_ID}" ]; then
    RUN_ID="${NEW_ID}"
    break
  fi
done

if [ -z "${RUN_ID}" ]; then
  check "phase 3: dispatched a new terraform-core-network.yml run" 1 "no new workflow_dispatch run id appeared within 40s"
else
  log_evidence "dispatched run at $(ts) -> $(run_url "${RUN_ID}")"

  plan_step_conclusion() {
    gh api "repos/${REPO}/actions/runs/${RUN_ID}/jobs" \
      --jq '.jobs[] | select(.name=="apply (dev)") | .steps[]? | select(.name | startswith("terraform apply")) | .conclusion' 2>/dev/null
  }

  APPLY_STEP_DONE=""
  for _ in $(seq 1 150); do
    APPLY_STEP_DONE="$(plan_step_conclusion)"
    if [ -n "${APPLY_STEP_DONE}" ] && [ "${APPLY_STEP_DONE}" != "null" ]; then
      break
    fi
    sleep 1
  done
  log_evidence "apply (dev)'s 'terraform apply' step reported conclusion='${APPLY_STEP_DONE}' at $(ts)"

  if [ "${APPLY_STEP_DONE}" != "success" ]; then
    check "phase 3: apply (dev)'s 'terraform apply' step reported success (needed before this drill's own deletion can prove anything)" 1 \
      "observed conclusion='${APPLY_STEP_DONE:-<none>}' -- run $(run_url "${RUN_ID}")"
  else
    dev_creds
    FLOW_BUCKET_NOW="$(tf output -raw flow_logs_bucket_name 2>/dev/null)"
    DELETE_CI_OUT="$(aws_ls s3 rb "s3://${FLOW_BUCKET_NOW}" --force)"
    log_evidence "deleted s3://${FLOW_BUCKET_NOW} at $(ts), immediately after 'terraform apply' reported success: ${DELETE_CI_OUT}"

    wait_for_job_status() {
      local job="$1" timeout="$2" elapsed=0 status
      while [ "${elapsed}" -lt "${timeout}" ]; do
        status="$(gh api "repos/${REPO}/actions/runs/${RUN_ID}/jobs" --jq ".jobs[] | select(.name==\"${job}\") | .status" 2>/dev/null)"
        [ "${status}" = "completed" ] && return 0
        sleep 2
        elapsed=$((elapsed + 2))
      done
      return 1
    }
    wait_for_job_status "apply (dev)" 120

    JOB_JSON="$(gh api "repos/${REPO}/actions/runs/${RUN_ID}/jobs" --jq '.jobs[] | select(.name=="apply (dev)")' 2>/dev/null)"
    JOB_CONCLUSION="$(printf '%s' "${JOB_JSON}" | jq -r '.conclusion')"
    APPLY_STEP_CONCL="$(printf '%s' "${JOB_JSON}" | jq -r '.steps[] | select(.name | startswith("terraform apply")) | .conclusion')"
    VERIFY_STEP_CONCL="$(printf '%s' "${JOB_JSON}" | jq -r '.steps[] | select(.name | startswith("verify-network.sh")) | .conclusion')"
    JOB_ID="$(printf '%s' "${JOB_JSON}" | jq -r '.id')"

    log_evidence "final: job='apply (dev)' conclusion='${JOB_CONCLUSION}' terraform-apply-step='${APPLY_STEP_CONCL}' verify-network.sh-step='${VERIFY_STEP_CONCL}' -- $(run_url "${RUN_ID}")"

    FAIL_LOG="$(gh run view --job "${JOB_ID}" --repo "${REPO}" --log-failed 2>/dev/null | grep -i "FAIL\|flow-logs bucket" | head -10)"
    log_evidence "verbatim FAIL evidence from the job log:"
    log_evidence "${FAIL_LOG}"

    CI_OK=0
    [ "${APPLY_STEP_CONCL}" = "success" ] || CI_OK=1
    [ "${VERIFY_STEP_CONCL}" = "failure" ] || CI_OK=1
    [ "${JOB_CONCLUSION}" = "failure" ] || CI_OK=1

    check "phase 3: run $(run_url "${RUN_ID}") shows 'terraform apply' step=success, 'verify-network.sh' step=failure, job=failure" "${CI_OK}" \
      "terraform-apply-step='${APPLY_STEP_CONCL}' verify-network.sh-step='${VERIFY_STEP_CONCL}' job='${JOB_CONCLUSION}'"
  fi
fi

restore_dev
RESTORE3_RC=$?
V3_RESTORE_LOG="$(bash "${REPO_ROOT}/scripts/verify-network.sh" dev 2>&1)"
V3_RESTORE_RC=$?
PLAN3_OUT="$(tf plan -input=false -detailed-exitcode -no-color 2>&1)"
PLAN3_RC=$?

check "phase 3: restore (terraform apply) succeeded after the CI proof" "${RESTORE3_RC}" "$(tail -5 /tmp/fake-success-drill-restore.log)"
check "phase 3: verify-network.sh dev green again after restore" "${V3_RESTORE_RC}" "$(printf '%s' "${V3_RESTORE_LOG}" | tail -3)"
check "phase 3: terraform plan -detailed-exitcode exits 0 after restore (no drift)" "$([ "${PLAN3_RC}" -eq 0 ] && echo 0 || echo 1)" \
  "exit=${PLAN3_RC}"
echo

echo "--- evidence log (also used to write docs/drills/fake-success-verification.md) ---"
cat "${EVIDENCE_LOG}"
rm -f "${EVIDENCE_LOG}"

echo
printf '[fake-success-drill] %s passed, %s failed, %s total.\n' \
  "${PASS_COUNT}" "${FAIL_COUNT}" "$((PASS_COUNT + FAIL_COUNT))"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
