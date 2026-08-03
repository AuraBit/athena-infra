#!/usr/bin/env bash
# verify.sh — smoke-verification dispatcher for the Athena estate (Plan 01,
# Task 3; RESEARCH.md "Validation Architecture" / Wave 0 Gaps).
#
# Discovers every scripts/verify-*.sh sibling in this script's own directory,
# sorted, and runs each one even if an earlier one fails — so one broken
# area never masks the rest. Prints a per-script PASS/FAIL line plus a final
# summary, and exits non-zero if any script failed (or if a filter argument
# matches nothing, so an empty run can never silently report success).
#
# This dispatcher is the extension point every later plan in this phase
# plugs into: add a new area's assertions by dropping in a new
# scripts/verify-<area>.sh — never edit this file. Reserved names (do not
# create until their owning plan lands): verify-clusters.sh (Plan 02),
# verify-localstack.sh (Plan 03), verify-governance.sh (Plan 04/05),
# verify-runner.sh (Plan 06).
#
# Usage:
#   scripts/verify.sh            # run every verify-*.sh sibling
#   scripts/verify.sh <filter>   # run only siblings whose filename matches <filter>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="${1:-}"

info()  { printf '[verify] %s\n' "$1"; }
ok()    { printf '\033[32m[verify] %s\033[0m\n' "$1"; }
fail()  { printf '\033[31m[verify] %s\033[0m\n' "$1"; }

mapfile -t CANDIDATES < <(find "${SCRIPT_DIR}" -maxdepth 1 -name 'verify-*.sh' -type f | sort)

TARGETS=()
for f in "${CANDIDATES[@]}"; do
  base="$(basename "${f}")"
  if [ -z "${FILTER}" ] || [[ "${base}" == *"${FILTER}"* ]]; then
    TARGETS+=("${f}")
  fi
done

if [ "${#TARGETS[@]}" -eq 0 ]; then
  if [ -n "${FILTER}" ]; then
    fail "No scripts/verify-*.sh sibling matched filter '${FILTER}'."
  else
    fail "No scripts/verify-*.sh siblings found in ${SCRIPT_DIR}."
  fi
  exit 1
fi

info "Running ${#TARGETS[@]} verification script(s)..."
echo

PASS_COUNT=0
FAIL_COUNT=0
FAILED_NAMES=()

for script in "${TARGETS[@]}"; do
  name="$(basename "${script}")"
  echo "--- ${name} ---"
  if bash "${script}"; then
    ok "PASS  ${name}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    fail "FAIL  ${name}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_NAMES+=("${name}")
  fi
  echo
done

info "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${#TARGETS[@]} total."

if [ "${FAIL_COUNT}" -gt 0 ]; then
  fail "Failing script(s): ${FAILED_NAMES[*]}"
  exit 1
fi

ok "All verification scripts passed."
