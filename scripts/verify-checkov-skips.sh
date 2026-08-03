#!/usr/bin/env bash
# verify-checkov-skips.sh — POL-04 / D-24 auditable-exception lint (Plan
# 02-04, Task 2).
#
# Every inline `# checkov:skip=<CHECK_ID>:<reason>` suppression anywhere
# under modules/ or envs/ must carry a real, non-empty, non-boilerplate
# justification after the check id — a reason-less skip is a security
# control disabled with no audit trail, and D-24's whole point is that the
# exception register stays auditable. A boilerplate reason ("todo", "n/a",
# ...) is a reason-less skip wearing a costume, so this script rejects
# those exactly the same way it rejects an empty one.
#
# This is deliberately the seed of POL-06's estate-wide exception-review
# process — a future phase generalizes this exact discipline (mandatory,
# lint-enforced, non-boilerplate justification for every suppressed
# control) beyond Checkov specifically. Recorded here because this script's
# header comment is the only place that connects the two for whoever writes
# POL-06.
#
# Named verify-checkov-skips.sh (not checkov-skip-lint.sh) purely so
# scripts/verify.sh's filename-convention auto-discovery (verify-*.sh)
# picks this script up with zero edits to that dispatcher.
#
# Deliberately not using `set -e` (house pattern — verify-governance.sh /
# verify-network.sh / verify-localstack.sh): one failing check must never
# abort the ones after it; scripts/verify.sh (this script's dispatcher)
# turns any FAIL here into a non-zero process exit.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."

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

# Boilerplate non-reasons — each one is rejected case-insensitively, after
# trimming surrounding whitespace and a trailing period, so "TODO", " todo "
# and "Todo." all match the same blocklist entry as "todo".
BOILERPLATE_REASONS=(
  "todo"
  "fixme"
  "n/a"
  "not applicable"
  "later"
  "see above"
  ""
)

is_boilerplate() {
  local candidate
  candidate="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//; s/[[:space:].]+$//')"
  local bad
  for bad in "${BOILERPLATE_REASONS[@]}"; do
    if [ "${candidate}" = "${bad}" ]; then
      return 0
    fi
  done
  return 1
}

cd "${REPO_ROOT}" || exit 1

MATCHES="$(grep -rn 'checkov:skip=' modules/ envs/ --include='*.tf' 2>/dev/null || true)"

if [ -z "${MATCHES}" ]; then
  # Zero suppressions is a legitimate, correct state (nothing to audit),
  # not a hole in this lint — record it as a pass so a filtered dispatcher
  # run (scripts/verify.sh checkov-skips) still reports something rather
  # than silently doing nothing.
  check "no inline checkov:skip suppressions found under modules/ or envs/ (vacuous pass is correct here: zero suppressions means zero exceptions to audit)" 0
else
  while IFS= read -r line; do
    [ -z "${line}" ] && continue

    LOCATION="$(printf '%s' "${line}" | cut -d: -f1-2)"
    CONTENT="$(printf '%s' "${line}" | cut -d: -f3-)"

    # Extract the check id and everything after its trailing colon from
    # "# checkov:skip=CKV2_AWS_11: some reason text".
    CHECK_ID="$(printf '%s' "${CONTENT}" | grep -oE 'checkov:skip=[A-Za-z0-9_]+' | sed 's/checkov:skip=//')"
    REASON="$(printf '%s' "${CONTENT}" | sed -E 's/.*checkov:skip=[A-Za-z0-9_]+:?//')"

    if [ -z "${CHECK_ID}" ]; then
      check "malformed checkov:skip directive at ${LOCATION}" 1 "content=[${CONTENT}]"
      continue
    fi

    if is_boilerplate "${REASON}"; then
      check "${LOCATION} — ${CHECK_ID} has a real, non-boilerplate justification" 1 \
        "reason=[${REASON}] is empty or matches the boilerplate blocklist (${BOILERPLATE_REASONS[*]})"
    else
      check "${LOCATION} — ${CHECK_ID} has a real, non-boilerplate justification" 0
    fi
  done <<<"${MATCHES}"
fi

echo
printf '[verify-checkov-skips] %s passed, %s failed, %s total.\n' \
  "${PASS_COUNT}" "${FAIL_COUNT}" "$((PASS_COUNT + FAIL_COUNT))"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
