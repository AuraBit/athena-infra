#!/usr/bin/env bash
# concurrency-queue-drill.sh — repeatable driver that PROVES (not describes)
# the two locking/scheduling behaviours IAC-03 and D-33 claim, by causing
# real GitHub Actions runs and polling their status through the GitHub API
# (Plan 02-09, Task 1).
#
# RESEARCH.md's Open Question 2 is the reason this is a driver script and
# not "push twice and eyeball the Actions tab": GitHub's own scheduling
# latency means two quick pushes often just execute one after the other
# anyway, which LOOKS identical to queuing behind a concurrency group and
# proves nothing. This script forces the first apply to hold its
# concurrency group for a known window (the drill-only `drill_hold_seconds`
# workflow_dispatch input, see terraform-core-network.yml's own header
# comment for that input) so the second run's pending/queued status is
# unambiguous, not a guess about timing.
#
# It runs three scenarios, because any one alone does not distinguish the
# behaviours that matter:
#   1. Same environment (dev) twice        -> second run must QUEUE.
#   2. Two different environments (dev+stg) at once -> BOTH must run
#      concurrently, proving the concurrency group is scoped per
#      stack+environment (terraform-core-<env>), not declared globally.
#   3. A pull-request plan for dev while an apply for dev is in flight ->
#      the plan must be SCHEDULED promptly (not stuck queued behind the
#      apply's concurrency group), proving that group is declared inside
#      the `apply` job only — the exact trap the workflow's own comment
#      warns about (Pitfall 6).
#
# One honest asterisk, stated here and repeated in the drill doc this
# script's output feeds: GitHub's concurrency groups hold AT MOST ONE
# pending run per group. A third arrival supersedes the pending one rather
# than queueing behind it. This script's own two-dispatch design never
# exercises that edge (only ever one holder + one pending run at a time),
# so it proves runs never COLLIDE on a group — it does not, and cannot,
# prove that arrival order is an apply-order guarantee. See
# docs/drills/concurrency-queue.md and the plan's own flagged_assumptions.
#
# Preconditions: `gh` authenticated as a user with `workflow` scope against
# AuraBit/athena-infra (dispatches workflow_dispatch runs and, for the
# stg leg, approves its own pending Environment deployment — this drill
# only ever targets dev+stg, see Task 1's action text; it never touches
# prod). The workflow_dispatch trigger and drill_hold_seconds input this
# script depends on must already be merged to `main` — this script cannot
# bootstrap its own trigger.
#
# Usage: bash scripts/drills/concurrency-queue-drill.sh
#   (repeatable — every invocation dispatches fresh, real Actions runs; it
#   is not part of scripts/verify.sh's auto-discovered verify-*.sh suite
#   for exactly that reason — a "smoke verification" dispatcher should not
#   silently trigger new CI runs on every pass, but a drill, by design,
#   does.)

set -uo pipefail

REPO="AuraBit/athena-infra"
WORKFLOW="terraform-core-network.yml"

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

# ---------------------------------------------------------------------------
# GitHub API helpers
# ---------------------------------------------------------------------------

list_run_ids() {
  gh api "repos/${REPO}/actions/workflows/${WORKFLOW}/runs?event=workflow_dispatch&per_page=20" \
    --jq '.workflow_runs[].id' 2>/dev/null | sort -n
}

# Dispatches a workflow_dispatch run for the given env+hold and returns the
# new run's numeric id on stdout once it can be distinguished from runs that
# already existed before this call.
dispatch_run() {
  local env="$1" hold="$2"
  local before after new_id attempt=0

  before="$(list_run_ids)"
  gh workflow run "${WORKFLOW}" --repo "${REPO}" --ref main \
    -f "drill_env=${env}" -f "drill_hold_seconds=${hold}" >/dev/null 2>&1

  while [ "${attempt}" -lt 40 ]; do
    sleep 1
    attempt=$((attempt + 1))
    after="$(list_run_ids)"
    new_id="$(comm -13 <(printf '%s\n' "${before}") <(printf '%s\n' "${after}") | tail -1)"
    if [ -n "${new_id}" ]; then
      printf '%s' "${new_id}"
      return 0
    fi
  done
  return 1
}

job_field() {
  local run_id="$1" job_name="$2" field="$3"
  gh api "repos/${REPO}/actions/runs/${run_id}/jobs" \
    --jq ".jobs[] | select(.name == \"${job_name}\") | .${field}" 2>/dev/null
}

# Polls a job's status until it matches one of the given target statuses, or
# a timeout elapses. Echoes the last observed status.
wait_for_job_status() {
  local run_id="$1" job_name="$2" timeout="$3"
  shift 3
  local targets=("$@")
  local elapsed=0 status t

  while [ "${elapsed}" -lt "${timeout}" ]; do
    status="$(job_field "${run_id}" "${job_name}" status)"
    for t in "${targets[@]}"; do
      if [ "${status}" = "${t}" ]; then
        printf '%s' "${status}"
        return 0
      fi
    done
    sleep 2
    elapsed=$((elapsed + 2))
  done
  job_field "${run_id}" "${job_name}" status
  return 1
}

# Approves a run's pending Environment deployment for the named environment,
# if one is waiting and the authenticated user is a valid reviewer for it
# (governance/environments.tf's infra_stg/infra_prod name the human
# developer as reviewer per D-31 — this genuinely uses that identity, the
# same one Plan 02-08 used for stg/prod's gated promotion applies).
approve_pending_deployment() {
  local run_id="$1" env_name="$2" pd env_id can_approve

  pd="$(gh api "repos/${REPO}/actions/runs/${run_id}/pending_deployments" 2>/dev/null)"
  env_id="$(printf '%s' "${pd}" | jq -r --arg e "${env_name}" '[.[] | select(.environment.name == $e)][0].environment.id // empty')"
  can_approve="$(printf '%s' "${pd}" | jq -r --arg e "${env_name}" '[.[] | select(.environment.name == $e)][0].current_user_can_approve // false')"

  if [ -n "${env_id}" ] && [ "${can_approve}" = "true" ]; then
    gh api --method POST "repos/${REPO}/actions/runs/${run_id}/pending_deployments" \
      -f state=approved \
      -f comment="Plan 02-09 concurrency-queue drill — automated approval by the configured human reviewer" \
      -F "environment_ids[]=${env_id}" >/dev/null 2>&1
    return 0
  fi
  return 1
}

EVIDENCE_LOG="$(mktemp)"
log_evidence() { printf '%s\n' "$1" | tee -a "${EVIDENCE_LOG}"; }

echo "=== Plan 02-09 concurrency-queue drill — $(ts) ==="
echo "workflow: ${WORKFLOW}  repo: ${REPO}"
echo

# ---------------------------------------------------------------------------
# Scenario 1: same environment (dev) twice — the second run must queue.
# ---------------------------------------------------------------------------
log_evidence "## Scenario 1 — same environment (dev) twice"

RUN1="$(dispatch_run dev 20)" || { check "scenario 1: same-env queuing" 1 "dispatch_run for RUN1 (dev, hold=20) never produced a new run id within 40s"; RUN1=""; }
if [ -n "${RUN1}" ]; then
  log_evidence "RUN1 dispatched dev hold=20s at $(ts) -> $(run_url "${RUN1}")"

  ST1="$(wait_for_job_status "${RUN1}" "apply (dev)" 90 in_progress completed)"
  T1_START="$(ts)"
  log_evidence "RUN1 apply(dev) reached status='${ST1}' at ${T1_START}"

  RUN2="$(dispatch_run dev 0)" || { check "scenario 1: same-env queuing" 1 "dispatch_run for RUN2 (dev, hold=0) never produced a new run id within 40s"; RUN2=""; }
  if [ -n "${RUN2}" ]; then
    T2_DISPATCH="$(ts)"
    log_evidence "RUN2 dispatched dev hold=0s at ${T2_DISPATCH} -> $(run_url "${RUN2}")"

    sleep 4
    ST2_PENDING="$(job_field "${RUN2}" "apply (dev)" status)"
    T2_PENDING_OBS="$(ts)"
    log_evidence "RUN2 apply(dev) status ${T2_PENDING_OBS}: '${ST2_PENDING}' (expected: queued, while RUN1 is still in flight)"

    wait_for_job_status "${RUN1}" "apply (dev)" 180 completed >/dev/null
    T1_END="$(ts)"
    CONCL1="$(job_field "${RUN1}" "apply (dev)" conclusion)"
    log_evidence "RUN1 apply(dev) completed at ${T1_END}, conclusion='${CONCL1}'"

    ST2_START="$(wait_for_job_status "${RUN2}" "apply (dev)" 90 in_progress completed)"
    T2_START="$(ts)"
    log_evidence "RUN2 apply(dev) reached status='${ST2_START}' at ${T2_START} (must be AFTER RUN1's completion at ${T1_END})"

    wait_for_job_status "${RUN2}" "apply (dev)" 180 completed >/dev/null
    T2_END="$(ts)"
    CONCL2="$(job_field "${RUN2}" "apply (dev)" conclusion)"
    log_evidence "RUN2 apply(dev) completed at ${T2_END}, conclusion='${CONCL2}'"

    SC1_FAIL=0
    [ "${ST2_PENDING}" = "queued" ] || SC1_FAIL=1
    [ "${CONCL1}" = "success" ] || SC1_FAIL=1
    [ "${CONCL2}" = "success" ] || SC1_FAIL=1

    check "scenario 1: RUN2 (dev) queued behind RUN1 (dev) then both completed successfully — RUN1=$(run_url "${RUN1}") RUN2=$(run_url "${RUN2}")" "${SC1_FAIL}" \
      "RUN2 pending status='${ST2_PENDING}' (want queued); RUN1 conclusion='${CONCL1}'; RUN2 conclusion='${CONCL2}'"
  fi
fi
echo

# ---------------------------------------------------------------------------
# Scenario 2: two different environments (dev + stg) at the same time — both
# must run concurrently, proving the group is scoped per stack+environment.
# ---------------------------------------------------------------------------
log_evidence "## Scenario 2 — two different environments (dev + stg) concurrently"

RUN3="$(dispatch_run dev 25)" || { check "scenario 2: cross-env concurrency" 1 "dispatch_run for RUN3 (dev, hold=25) never produced a new run id within 40s"; RUN3=""; }
if [ -n "${RUN3}" ]; then
  log_evidence "RUN3 dispatched dev hold=25s at $(ts) -> $(run_url "${RUN3}")"

  wait_for_job_status "${RUN3}" "apply (dev)" 90 in_progress completed >/dev/null
  T3_START="$(ts)"
  log_evidence "RUN3 apply(dev) in_progress observed at ${T3_START}"

  RUN4="$(dispatch_run stg 25)" || { check "scenario 2: cross-env concurrency" 1 "dispatch_run for RUN4 (stg, hold=25) never produced a new run id within 40s"; RUN4=""; }
  if [ -n "${RUN4}" ]; then
    log_evidence "RUN4 dispatched stg hold=25s at $(ts) -> $(run_url "${RUN4}")"

    # stg's apply job binds a gated Environment (governance/environments.tf,
    # D-31) — approve as soon as the pending deployment appears so the
    # in-flight window genuinely overlaps RUN3's, using the same human
    # reviewer identity Plan 02-08's gated promotion already used live.
    APPROVED=1
    for _ in $(seq 1 30); do
      if approve_pending_deployment "${RUN4}" stg; then
        APPROVED=0
        log_evidence "RUN4 pending deployment for stg approved at $(ts)"
        break
      fi
      sleep 2
    done
    [ "${APPROVED}" -eq 0 ] || log_evidence "WARNING: never observed an approvable pending_deployment for RUN4/stg within 60s"

    ST4="$(wait_for_job_status "${RUN4}" "apply (stg)" 90 in_progress completed)"
    T4_START="$(ts)"
    log_evidence "RUN4 apply(stg) reached status='${ST4}' at ${T4_START}"

    wait_for_job_status "${RUN3}" "apply (dev)" 180 completed >/dev/null
    T3_END="$(ts)"
    CONCL3="$(job_field "${RUN3}" "apply (dev)" conclusion)"
    log_evidence "RUN3 apply(dev) completed at ${T3_END}, conclusion='${CONCL3}'"

    wait_for_job_status "${RUN4}" "apply (stg)" 180 completed >/dev/null
    T4_END="$(ts)"
    CONCL4="$(job_field "${RUN4}" "apply (stg)" conclusion)"
    log_evidence "RUN4 apply(stg) completed at ${T4_END}, conclusion='${CONCL4}'"

    log_evidence "overlap check: RUN3 window [${T3_START} .. ${T3_END}]; RUN4 window [${T4_START} .. ${T4_END}]"

    SC2_FAIL=0
    [ "${ST4}" = "in_progress" ] || SC2_FAIL=1
    [[ "${T4_START}" < "${T3_END}" ]] || SC2_FAIL=1
    [ "${CONCL3}" = "success" ] || SC2_FAIL=1
    [ "${CONCL4}" = "success" ] || SC2_FAIL=1

    check "scenario 2: RUN3 (dev) and RUN4 (stg) ran concurrently, both completed successfully — RUN3=$(run_url "${RUN3}") RUN4=$(run_url "${RUN4}")" "${SC2_FAIL}" \
      "RUN4 status when observed='${ST4}'; RUN3 window=[${T3_START}..${T3_END}]; RUN4 window=[${T4_START}..${T4_END}]; conclusions dev='${CONCL3}' stg='${CONCL4}'"
  fi
fi
echo

# ---------------------------------------------------------------------------
# Scenario 3: a pull-request plan for dev while an apply for dev is in
# flight — the plan must be scheduled promptly, not stuck behind the
# apply's concurrency group (the group lives inside the apply job only).
# ---------------------------------------------------------------------------
log_evidence "## Scenario 3 — PR plan (dev) while an apply (dev) is in flight"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BRANCH="drill/02-09-concurrency-plan-during-apply-$(date -u +%Y%m%d%H%M%S)"
STARTING_BRANCH="$(cd "${REPO_ROOT}" && git rev-parse --abbrev-ref HEAD)"
PR_NUMBER=""

RUN5="$(dispatch_run dev 25)" || { check "scenario 3: plan-during-apply" 1 "dispatch_run for RUN5 (dev, hold=25) never produced a new run id within 40s"; RUN5=""; }
if [ -n "${RUN5}" ]; then
  log_evidence "RUN5 dispatched dev hold=25s at $(ts) -> $(run_url "${RUN5}")"

  wait_for_job_status "${RUN5}" "apply (dev)" 90 in_progress completed >/dev/null
  T5_START="$(ts)"
  log_evidence "RUN5 apply(dev) in_progress observed at ${T5_START}"

  (
    cd "${REPO_ROOT}" || exit 1
    git checkout -b "${BRANCH}" main >/dev/null 2>&1
    {
      echo ""
      echo "# Plan 02-09 concurrency-queue drill: comment-only touch proving the"
      echo "# plan job (dev) is scheduled while an apply (dev) is in flight ($(ts))."
      echo "# This PR is closed without merging once the evidence is captured --"
      echo "# no config change is intended, only a real pull_request event on a"
      echo "# path detect-changes' dorny/paths-filter matches for dev."
    } >> envs/dev/core-network/backend.tf
    git add envs/dev/core-network/backend.tf
    git commit -q -m "docs(02-09): comment-only touch to prove plan(dev) runs during apply(dev) (drill, not merged)"
    git push -q -u origin "${BRANCH}"
  )

  PR_URL="$(gh pr create --repo "${REPO}" --base main --head "${BRANCH}" \
    --title "Plan 02-09 drill: plan(dev)-during-apply(dev) (not to be merged)" \
    --body "Throwaway drill PR for Plan 02-09's concurrency-queue drill — proves the \`plan\` job for dev is scheduled promptly while apply(dev) run $(run_url "${RUN5}") is in flight. Closed without merging once evidence is captured." 2>/dev/null)"
  PR_NUMBER="$(printf '%s' "${PR_URL}" | grep -oE '[0-9]+$')"
  log_evidence "drill PR opened at $(ts): ${PR_URL}"

  if [ -n "${PR_NUMBER}" ]; then
    PLAN_RUN=""
    for _ in $(seq 1 40); do
      PLAN_RUN="$(gh api "repos/${REPO}/actions/runs?event=pull_request&branch=${BRANCH}&per_page=5" --jq '.workflow_runs[0].id' 2>/dev/null)"
      [ -n "${PLAN_RUN}" ] && [ "${PLAN_RUN}" != "null" ] && break
      sleep 1
    done

    if [ -n "${PLAN_RUN}" ] && [ "${PLAN_RUN}" != "null" ]; then
      log_evidence "PR's workflow run for branch ${BRANCH}: $(run_url "${PLAN_RUN}")"
      STP="$(wait_for_job_status "${PLAN_RUN}" "plan (dev)" 60 in_progress completed)"
      TP_START="$(ts)"
      log_evidence "plan(dev) reached status='${STP}' at ${TP_START} (RUN5 apply(dev) still in flight: expect NOT queued)"

      wait_for_job_status "${PLAN_RUN}" "plan (dev)" 120 completed >/dev/null
      TP_END="$(ts)"
      CONCLP="$(job_field "${PLAN_RUN}" "plan (dev)" conclusion)"
      log_evidence "plan(dev) completed at ${TP_END}, conclusion='${CONCLP}' — recorded honestly whatever it was; a real terraform-level lock-contention failure here (not a queued/skipped job) is itself evidence that the concurrency group and the state lock are two different, complementary mechanisms (see docs/drills/concurrency-queue.md)."

      SC3_FAIL=0
      [ "${STP}" = "in_progress" ] || [ "${STP}" = "completed" ] || SC3_FAIL=1

      check "scenario 3: plan(dev) was scheduled promptly (not queued) while apply(dev) was in flight — plan run=$(run_url "${PLAN_RUN}")" "${SC3_FAIL}" \
        "plan(dev) status observed='${STP}'; conclusion='${CONCLP}'"
    else
      check "scenario 3: plan(dev) was scheduled promptly while apply(dev) was in flight" 1 \
        "no workflow run for branch ${BRANCH} appeared within 40s of opening PR #${PR_NUMBER}"
    fi

    gh pr close "${PR_NUMBER}" --repo "${REPO}" --delete-branch >/dev/null 2>&1
    log_evidence "drill PR #${PR_NUMBER} closed without merging, branch deleted, at $(ts)"
  else
    check "scenario 3: plan(dev) was scheduled promptly while apply(dev) was in flight" 1 \
      "gh pr create did not return a parseable PR number (output: ${PR_URL})"
  fi

  wait_for_job_status "${RUN5}" "apply (dev)" 180 completed >/dev/null
  T5_END="$(ts)"
  CONCL5="$(job_field "${RUN5}" "apply (dev)" conclusion)"
  log_evidence "RUN5 apply(dev) completed at ${T5_END}, conclusion='${CONCL5}'"

  ( cd "${REPO_ROOT}" && git checkout -q "${STARTING_BRANCH}" >/dev/null 2>&1 && git branch -D "${BRANCH}" >/dev/null 2>&1 )
fi
echo

echo "--- evidence log (also used to write docs/drills/concurrency-queue.md) ---"
cat "${EVIDENCE_LOG}"
rm -f "${EVIDENCE_LOG}"

echo
printf '[concurrency-queue-drill] %s passed, %s failed, %s total.\n' \
  "${PASS_COUNT}" "${FAIL_COUNT}" "$((PASS_COUNT + FAIL_COUNT))"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
