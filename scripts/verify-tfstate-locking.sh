#!/usr/bin/env bash
# verify-tfstate-locking.sh — standing proof that Terraform's native S3
# lockfile locking genuinely acquires, blocks a concurrent operation, and
# releases against this LocalStack account (Plan 02-01, Task 3; IAC-02).
#
# RESEARCH.md's Common Pitfalls #1 / Open Question 1 / Assumption A1 name the
# one genuinely open technical risk this phase carries: does LocalStack's S3
# implementation honor the `If-None-Match` conditional-PutObject semantics
# Terraform's `use_lockfile` depends on, under real concurrent access — not
# just a single sequential `terraform apply`? Everything downstream (success
# criterion 1, the mandatory concurrency-queue drill D-33, every later
# Phase 6 stack reusing this same pattern) is built on it holding. This
# script is the standing assertion that closes that question, not a one-off
# observation: it is a permanent scripts/verify-*.sh sibling (the PATTERNS
# map's own question — disposable one-off vs. permanent sibling — resolved
# in favor of permanent) because locking silently regressing after a future
# LocalStack image bump is exactly the kind of drift this estate's
# dispatcher exists to catch, and it picks this file up for free.
#
# What this proves, against the real envs/dev/core-network state (both
# operations below are `terraform plan` — read-only; neither creates,
# modifies, nor destroys the applied VPC):
#   1. Acquire  — a real Terraform operation's own .tflock object
#      (core-network/terraform.tfstate.tflock in athena-tfstate-dev)
#      appears in S3 while that operation is genuinely in flight.
#   2. Contention — a second, concurrent `terraform plan -lock-timeout=0`
#      against the same state is refused with a real lock-contention error
#      naming the lock holder (Terraform's own "Error acquiring the state
#      lock" / "Lock Info" output) — a silent double-success here would be
#      the state-corruption signature and is a hard FAIL, never tolerated.
#   3. Release — after the holding operation completes, the .tflock object
#      is gone. A lock acquired but never released is the "force-unlock
#      needed on every run" signature RESEARCH names as the warning sign
#      that this assumption did not hold.
#
# A no-op `terraform plan` against this account was empirically timed at
# ~5s wall-clock (mostly Terraform's own provider-plugin startup and the
# refresh round trip to LocalStack) — comfortably long enough for this
# script's poll loop to observe the lock object mid-flight and for a second
# concurrent invocation to genuinely race it, without needing any artificial
# delay or dummy resource added to the real config.
#
# If any of the three assertions below fails, that is a real finding that
# reshapes this phase's IAC-02/IAC-03 story — not a bug in this script — and
# the script says so rather than trying to route around it. D-33's
# stale-lock recovery drill (Plan 02-09) is where the human remediation
# procedure (force-unlock decision, runbook entry) gets written down; this
# script's own cleanup trap force-unlocks only the exact lock ID it
# observed itself, and only if that lock is still present when the script
# exits — it never force-unlocks a lock it did not itself create or verify.
#
# Deliberately not using `set -e` (mirrors verify-localstack.sh /
# verify-network.sh): every fallible command is captured first so one
# failing check never aborts the ones after it; scripts/verify.sh (this
# script's dispatcher) is what turns any FAIL here into a non-zero process
# exit.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
ENV_DIR="${REPO_ROOT}/envs/dev/core-network"
LS_ENDPOINT="http://localhost:4566"
BUCKET="athena-tfstate-dev"
STATE_KEY="core-network/terraform.tfstate"
LOCK_KEY="${STATE_KEY}.tflock"

# shellcheck source=./tf-env.sh
. "${SCRIPT_DIR}/tf-env.sh" dev

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

AWSLOCAL_BIN=""
if command -v awslocal >/dev/null 2>&1; then
  AWSLOCAL_BIN="awslocal"
fi

aws_ls() {
  if [ -n "${AWSLOCAL_BIN}" ]; then
    "${AWSLOCAL_BIN}" "$@"
  else
    aws --endpoint-url "${LS_ENDPOINT}" "$@"
  fi
}

PLAN_A_LOG="$(mktemp)"
LOCK_OBJ_TMP="$(mktemp)"
LOCK_ID_HELD=""

cleanup() {
  rm -f "${PLAN_A_LOG}" "${LOCK_OBJ_TMP}"
  # Force-unlock ONLY the exact lock ID this script itself observed itself
  # acquiring, and ONLY if it is still present when the script exits (e.g.
  # this script was killed mid-run) — never a lock this script did not
  # itself create or verify.
  if [ -n "${LOCK_ID_HELD}" ]; then
    if aws_ls s3api head-object --bucket "${BUCKET}" --key "${LOCK_KEY}" >/dev/null 2>&1; then
      echo "[verify-tfstate-locking] cleanup: lock ${LOCK_ID_HELD} still present at exit — force-unlocking this exact ID only" >&2
      (cd "${ENV_DIR}" && terraform force-unlock -force "${LOCK_ID_HELD}" >/dev/null 2>&1) || true
    fi
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Acquire — launch a real, unmodified `terraform plan` against the applied
#    dev state as a background process, then poll for its own .tflock object
#    appearing in S3 while that process is still running.
# ---------------------------------------------------------------------------
(
  cd "${ENV_DIR}" && terraform plan -input=false -lock-timeout=0s -detailed-exitcode
) >"${PLAN_A_LOG}" 2>&1 &
PLAN_A_PID=$!

ACQUIRE_OK=1
ACQUIRE_OBSERVED=""
for _ in $(seq 1 20); do
  if ! kill -0 "${PLAN_A_PID}" 2>/dev/null; then
    break
  fi
  if aws_ls s3api head-object --bucket "${BUCKET}" --key "${LOCK_KEY}" >/dev/null 2>&1; then
    ACQUIRE_OK=0
    break
  fi
  sleep 0.25
done

if [ "${ACQUIRE_OK}" -eq 0 ]; then
  if aws_ls s3api get-object --bucket "${BUCKET}" --key "${LOCK_KEY}" "${LOCK_OBJ_TMP}" >/dev/null 2>&1; then
    LOCK_ID_HELD="$(jq -r '.ID // empty' "${LOCK_OBJ_TMP}" 2>/dev/null)"
  fi
  check "acquire: ${LOCK_KEY} appears in s3://${BUCKET} while a real terraform plan is in flight (lock ID ${LOCK_ID_HELD:-unknown})" 0
else
  ACQUIRE_OBSERVED="polled s3://${BUCKET}/${LOCK_KEY} for up to 5s while PID ${PLAN_A_PID} ran; head-object never returned 200 before the process finished"
  check "acquire: ${LOCK_KEY} appears in s3://${BUCKET} while a real terraform plan is in flight" 1 "${ACQUIRE_OBSERVED}"
fi

# ---------------------------------------------------------------------------
# 2. Contention — while plan A still holds the lock, a second concurrent
#    `terraform plan -lock-timeout=0` must be refused with a real
#    lock-contention error naming the holder. A silent success here is the
#    state-corruption signature and is asserted as a hard FAIL.
# ---------------------------------------------------------------------------
CONTENTION_OK=1
CONTENTION_OBSERVED=""
LOCK_INFO_SEEN=""
if kill -0 "${PLAN_A_PID}" 2>/dev/null; then
  PLAN_B_OUT="$(cd "${ENV_DIR}" && terraform plan -input=false -no-color -lock-timeout=0s 2>&1)"
  PLAN_B_EXIT=$?
  if [ "${PLAN_B_EXIT}" -ne 0 ] && printf '%s' "${PLAN_B_OUT}" | grep -q 'Error acquiring the state lock'; then
    LOCK_INFO_SEEN="$(printf '%s' "${PLAN_B_OUT}" | grep -A6 'Lock Info:' | tr -s ' \n' ' ')"
    CONTENTION_OK=0
    check "contention: a second concurrent plan (-lock-timeout=0) is refused, naming the lock holder" 0
    printf '      lock-holder detail observed: %s\n' "${LOCK_INFO_SEEN}"
  else
    CONTENTION_OBSERVED="second plan exit=${PLAN_B_EXIT} (expected non-zero + 'Error acquiring the state lock'); tail=[$(printf '%s' "${PLAN_B_OUT}" | tail -5 | tr '\n' ' ')]"
    check "contention: a second concurrent plan (-lock-timeout=0) is refused, naming the lock holder" 1 "${CONTENTION_OBSERVED}"
  fi
else
  CONTENTION_OBSERVED="plan A (PID ${PLAN_A_PID}) had already finished before the contention probe could run — the lock window closed faster than this run's timing allowed"
  check "contention: a second concurrent plan (-lock-timeout=0) is refused, naming the lock holder" 1 "${CONTENTION_OBSERVED}"
fi

# ---------------------------------------------------------------------------
# 3. Release — wait for plan A to finish, then assert its .tflock object is
#    gone. A lock acquired but never released is the warning sign RESEARCH
#    flags as "force-unlock needed on every run."
# ---------------------------------------------------------------------------
wait "${PLAN_A_PID}"
PLAN_A_EXIT=$?
if [ "${PLAN_A_EXIT}" -ne 0 ]; then
  echo "[verify-tfstate-locking] note: background plan A exited ${PLAN_A_EXIT}:" >&2
  cat "${PLAN_A_LOG}" >&2
fi

if aws_ls s3api head-object --bucket "${BUCKET}" --key "${LOCK_KEY}" >/dev/null 2>&1; then
  check "release: ${LOCK_KEY} is gone after the holding operation completes" 1 \
    "head-object still returns 200 for ${LOCK_KEY} after plan A (PID ${PLAN_A_PID}, exit ${PLAN_A_EXIT}) finished"
else
  check "release: ${LOCK_KEY} is gone after the holding operation completes" 0
  LOCK_ID_HELD="" # confirmed released — nothing left for the cleanup trap to force-unlock
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
printf '[verify-tfstate-locking] %s passed, %s failed, %s total.\n' \
  "${PASS_COUNT}" "${FAIL_COUNT}" "$((PASS_COUNT + FAIL_COUNT))"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
