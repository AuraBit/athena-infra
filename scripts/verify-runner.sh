#!/usr/bin/env bash
# verify-runner.sh — CI-05, CI-06, FOUND-05 assertions for the self-hosted
# runner and the act inner loop (Plan 06).
#
# Mirrors verify-governance.sh's shape: every check asserts live state (the
# systemd unit, the organisation's runners API, the journal, the workflow
# files on disk, a real `act` invocation) rather than trusting that the
# Ansible role or the workflow file merely *exists*. Deliberately not using
# `set -e` (mirrors verify-skeleton.sh/verify-governance.sh): every fallible
# command is captured into a variable first so one failing check never
# aborts the ones after it; scripts/verify.sh (this script's dispatcher) is
# what turns any FAIL here into a non-zero process exit.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
ESTATE_ROOT="${REPO_ROOT}/.."
RUNNER_USER="athena-runner"
RUNNER_HOME="/home/athena-runner"
EXPECTED_LABEL="athena-local"
RUNNER_DEFAULTS="${REPO_ROOT}/ansible/roles/github-runner/defaults/main.yml"

# Read expected toolchain versions out of the role's own defaults rather
# than duplicating the literals here — Plan 02-02's key_link between this
# script and defaults/main.yml depends on the two never being able to drift.
read_default() {
  grep -oE "^$1: \"[^\"]+\"" "${RUNNER_DEFAULTS}" | sed -E "s/^$1: \"([^\"]+)\"/\1/"
}
EXPECTED_TERRAFORM_VERSION="$(read_default athena_terraform_version)"
EXPECTED_CHECKOV_VERSION="$(read_default athena_checkov_version)"
EXPECTED_NAME_PREFIX="$(read_default athena_runner_name_prefix)"
EXPECTED_POOL_SIZE="$(grep -oE '^athena_runner_pool_size: [0-9]+' "${RUNNER_DEFAULTS}" | grep -oE '[0-9]+$')"
WORKFLOWS=(
  "${REPO_ROOT}/.github/workflows/lint.yml"
  "${REPO_ROOT}/.github/workflows/heavy-selfhosted.yml"
  "${ESTATE_ROOT}/athena-app/.github/workflows/lint.yml"
  "${ESTATE_ROOT}/athena-gitops/.github/workflows/lint.yml"
  "${ESTATE_ROOT}/athena-docs/.github/workflows/lint.yml"
)

# GITHUB_OWNER / GH_RUNNER_REG_PAT must already be exported (see
# docs/runbooks/github-bootstrap.md — `set -a; . estate/athena-infra/.governance.env; set +a`).
: "${GITHUB_OWNER:?GITHUB_OWNER must be exported — see docs/runbooks/github-bootstrap.md}"
: "${GH_RUNNER_REG_PAT:?GH_RUNNER_REG_PAT must be exported — see docs/runbooks/github-bootstrap.md}"

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

gh_runner_api() {
  curl -sS -H "Authorization: Bearer ${GH_RUNNER_REG_PAT}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/orgs/${GITHUB_OWNER}$1"
}

# ---------------------------------------------------------------------------
# 1. Every pool instance's systemd unit is enabled and active, and the
#    pre-pool single unit (athena-runner.service, no @N) is gone (D-12,
#    Plan 02-02 Task 3) — an administrator who forgot to retire it would
#    otherwise be running pool_size+1 registered runners, not pool_size.
# ---------------------------------------------------------------------------
for i in $(seq 1 "${EXPECTED_POOL_SIZE}"); do
  UNIT_ENABLED="$(systemctl is-enabled "athena-runner@${i}" 2>/dev/null || true)"
  UNIT_ACTIVE="$(systemctl is-active "athena-runner@${i}" 2>/dev/null || true)"
  if [ "${UNIT_ENABLED}" = "enabled" ] && [ "${UNIT_ACTIVE}" = "active" ]; then
    check "athena-runner@${i}.service is enabled and active" 0
  else
    check "athena-runner@${i}.service is enabled and active" 1 \
      "enabled=[${UNIT_ENABLED}] active=[${UNIT_ACTIVE}]"
  fi
done

LEGACY_UNIT_LISTING="$(systemctl list-unit-files athena-runner.service --no-legend 2>/dev/null || true)"
if [ -z "${LEGACY_UNIT_LISTING}" ]; then
  check "pre-pool athena-runner.service (no @N) is retired" 0
else
  check "pre-pool athena-runner.service (no @N) is retired" 1 \
    "observed=[${LEGACY_UNIT_LISTING}]"
fi

# ---------------------------------------------------------------------------
# 2. Org reports >=pool_size online runners carrying the estate label, with
#    distinct names all prefixed with the role's naming prefix, and the
#    ephemeral flag is set. The org-level runners API omits `ephemeral` from
#    both the list and detail endpoints for this org (live finding, this
#    plan — the field is documented as optional in GitHub's own OpenAPI
#    schema but consistently absent from every response observed while
#    building this role), so ephemerality is instead read from the runner's
#    own local `.runner` bookkeeping file, which JIT registration writes
#    with "Ephemeral":"True" — a stronger source of truth than an API field
#    that may simply be unset, since it comes from the runner's actual
#    registered state rather than a list response.
# ---------------------------------------------------------------------------
RUNNERS_JSON="$(gh_runner_api "/actions/runners?per_page=100")"
ONLINE_LABELED_COUNT="$(printf '%s' "${RUNNERS_JSON}" | jq --arg label "${EXPECTED_LABEL}" \
  '[.runners[] | select(.status=="online") | select([.labels[].name] | index($label))] | length' 2>/dev/null || echo 0)"
if [ "${ONLINE_LABELED_COUNT}" -ge "${EXPECTED_POOL_SIZE}" ] 2>/dev/null; then
  check "organisation reports >=${EXPECTED_POOL_SIZE} online runner(s) carrying the '${EXPECTED_LABEL}' label" 0
else
  check "organisation reports >=${EXPECTED_POOL_SIZE} online runner(s) carrying the '${EXPECTED_LABEL}' label" 1 \
    "online_labeled_count=[${ONLINE_LABELED_COUNT}] expected_pool_size=[${EXPECTED_POOL_SIZE}]"
fi

ONLINE_LABELED_NAMES="$(printf '%s' "${RUNNERS_JSON}" | jq -r --arg label "${EXPECTED_LABEL}" \
  '[.runners[] | select(.status=="online") | select([.labels[].name] | index($label)) | .name] | unique | .[]' 2>/dev/null || true)"
DISTINCT_NAME_COUNT="$(printf '%s\n' "${ONLINE_LABELED_NAMES}" | grep -c . || true)"
NON_PREFIXED_COUNT="$(printf '%s\n' "${ONLINE_LABELED_NAMES}" | grep -vc "^${EXPECTED_NAME_PREFIX}-" || true)"
if [ "${DISTINCT_NAME_COUNT}" -ge "${EXPECTED_POOL_SIZE}" ] 2>/dev/null && [ "${NON_PREFIXED_COUNT}" = "0" ]; then
  check "online labeled runners have distinct names, all prefixed '${EXPECTED_NAME_PREFIX}-'" 0
else
  check "online labeled runners have distinct names, all prefixed '${EXPECTED_NAME_PREFIX}-'" 1 \
    "names=[$(printf '%s' "${ONLINE_LABELED_NAMES}" | tr '\n' ',')]"
fi

RUNNER_FILE_JSON="$(sudo cat "${RUNNER_HOME}/.runner" 2>/dev/null || true)"
RUNNER_EPHEMERAL="$(printf '%s' "${RUNNER_FILE_JSON}" | jq -r '.Ephemeral // empty' 2>/dev/null || true)"
for i in $(seq 1 "${EXPECTED_POOL_SIZE}"); do
  if [ "${RUNNER_EPHEMERAL}" = "True" ]; then
    check "pool instance ${i}'s registration state (.runner) reports Ephemeral=True" 0
  else
    check "pool instance ${i}'s registration state (.runner) reports Ephemeral=True" 1 \
      "observed=[${RUNNER_EPHEMERAL}] (raw: ${RUNNER_FILE_JSON:0:200})"
  fi
done

# ---------------------------------------------------------------------------
# 3. Runner OS user exists and is in the docker group
# ---------------------------------------------------------------------------
RUNNER_GROUPS="$(id -nG "${RUNNER_USER}" 2>/dev/null || true)"
if printf '%s' "${RUNNER_GROUPS}" | grep -qw docker; then
  check "OS user '${RUNNER_USER}' exists and is in the docker group" 0
else
  check "OS user '${RUNNER_USER}' exists and is in the docker group" 1 \
    "id -nG ${RUNNER_USER} => [${RUNNER_GROUPS}]"
fi

# ---------------------------------------------------------------------------
# 3b. Pinned CI toolchain (D-14; Plan 02-02) — terraform, checkov, awslocal
#     must each resolve for the runner user and report the version pinned
#     in defaults/main.yml. A missing/wrong-version tool here is a red
#     verification run, not a CI surprise.
# ---------------------------------------------------------------------------
TERRAFORM_OUT="$(sudo -u "${RUNNER_USER}" bash -lc 'terraform version' 2>&1 || true)"
if printf '%s' "${TERRAFORM_OUT}" | grep -qF "Terraform v${EXPECTED_TERRAFORM_VERSION}"; then
  check "terraform resolves for ${RUNNER_USER} at pinned version ${EXPECTED_TERRAFORM_VERSION}" 0
else
  check "terraform resolves for ${RUNNER_USER} at pinned version ${EXPECTED_TERRAFORM_VERSION}" 1 \
    "observed=[${TERRAFORM_OUT}]"
fi

CHECKOV_OUT="$(sudo -u "${RUNNER_USER}" bash -lc 'checkov --version' 2>&1 || true)"
if printf '%s' "${CHECKOV_OUT}" | grep -qF "${EXPECTED_CHECKOV_VERSION}"; then
  check "checkov resolves for ${RUNNER_USER} at pinned version ${EXPECTED_CHECKOV_VERSION}" 0
else
  check "checkov resolves for ${RUNNER_USER} at pinned version ${EXPECTED_CHECKOV_VERSION}" 1 \
    "observed=[${CHECKOV_OUT}]"
fi

sudo -u "${RUNNER_USER}" bash -lc 'awslocal --version' >/dev/null 2>&1
AWSLOCAL_RC=$?
if [ "${AWSLOCAL_RC}" -eq 0 ]; then
  check "awslocal resolves and runs for ${RUNNER_USER}" 0
else
  check "awslocal resolves and runs for ${RUNNER_USER}" 1 "rc=${AWSLOCAL_RC}"
fi

# ---------------------------------------------------------------------------
# 4. No world-readable file under the runner home contains the registration
#    PAT, and the journal carries no token-shaped string. Reads the PAT
#    value only into this shell's own memory for a local grep — it is never
#    echoed, logged, or written anywhere.
# ---------------------------------------------------------------------------
PAT_LEAK_FILES="$(sudo find "${RUNNER_HOME}" -perm -o=r -type f -exec grep -l "${GH_RUNNER_REG_PAT}" {} \; 2>/dev/null || true)"
if [ -z "${PAT_LEAK_FILES}" ]; then
  check "no world-readable file under ${RUNNER_HOME} contains the registration PAT" 0
else
  check "no world-readable file under ${RUNNER_HOME} contains the registration PAT" 1 \
    "leaked_in=[${PAT_LEAK_FILES}]"
fi

JOURNAL_UNITS=()
for i in $(seq 1 "${EXPECTED_POOL_SIZE}"); do
  JOURNAL_UNITS+=("-u" "athena-runner@${i}")
done
JOURNAL_TOKEN_COUNT="$(sudo journalctl "${JOURNAL_UNITS[@]}" --no-pager 2>/dev/null | grep -Ec 'ghp_|github_pat_' || true)"
if [ "${JOURNAL_TOKEN_COUNT}" = "0" ]; then
  check "athena-runner pool journals contain no token-shaped string (ghp_/github_pat_)" 0
else
  check "athena-runner pool journals contain no token-shaped string (ghp_/github_pat_)" 1 \
    "match_count=[${JOURNAL_TOKEN_COUNT}]"
fi

# ---------------------------------------------------------------------------
# 5. heavy-selfhosted.yml declares no PR-family trigger, and its job carries
#    the protected-branch condition
# ---------------------------------------------------------------------------
HEAVY_WF="${REPO_ROOT}/.github/workflows/heavy-selfhosted.yml"
PR_TRIGGER_COUNT="$(grep -cE 'pull_request' "${HEAVY_WF}" 2>/dev/null || true)"
if [ "${PR_TRIGGER_COUNT}" = "0" ]; then
  check "heavy-selfhosted.yml declares no pull_request-family trigger" 0
else
  check "heavy-selfhosted.yml declares no pull_request-family trigger" 1 \
    "match_count=[${PR_TRIGGER_COUNT}]"
fi

HAS_BRANCH_GUARD="$(grep -cE "refs/heads/main" "${HEAVY_WF}" 2>/dev/null || true)"
if [ "${HAS_BRANCH_GUARD}" -ge 1 ] 2>/dev/null; then
  check "heavy-selfhosted.yml's job carries a protected-branch (refs/heads/main) condition" 0
else
  check "heavy-selfhosted.yml's job carries a protected-branch (refs/heads/main) condition" 1 \
    "match_count=[${HAS_BRANCH_GUARD}]"
fi

# ---------------------------------------------------------------------------
# 6. Across every workflow file in this repo, the count of non-local `uses:`
#    references not terminating in a full-length hex SHA is zero
# ---------------------------------------------------------------------------
UNPINNED_COUNT=0
UNPINNED_LIST=()
for wf in "${WORKFLOWS[@]}"; do
  if [ -f "${wf}" ]; then
    while IFS= read -r line; do
      [ -z "${line}" ] && continue
      UNPINNED_COUNT=$((UNPINNED_COUNT + 1))
      UNPINNED_LIST+=("${wf#"${ESTATE_ROOT}"/}:${line}")
    done < <(grep -oE 'uses: *[^ ]+' "${wf}" | sed 's/^uses: *//' | grep -v '^\./' | grep -vE '@[0-9a-f]{40}$' || true)
  fi
done
if [ "${UNPINNED_COUNT}" -eq 0 ]; then
  check "every non-local 'uses:' reference across this estate's workflows is SHA-pinned" 0
else
  check "every non-local 'uses:' reference across this estate's workflows is SHA-pinned" 1 \
    "unpinned=[${UNPINNED_LIST[*]}]"
fi

# ---------------------------------------------------------------------------
# 7. act itself: version probe, and it can list the lint workflow's jobs
# ---------------------------------------------------------------------------
ACT_VERSION_OUT="$(act --version 2>&1)"
ACT_VERSION_RC=$?
if [ "${ACT_VERSION_RC}" -eq 0 ]; then
  check "act --version succeeds (${ACT_VERSION_OUT})" 0
else
  check "act --version succeeds" 1 "rc=${ACT_VERSION_RC} output=[${ACT_VERSION_OUT}]"
fi

ACT_LIST_OUT="$(cd "${REPO_ROOT}" && act -l -W .github/workflows/lint.yml 2>&1)"
if printf '%s' "${ACT_LIST_OUT}" | grep -qw lint; then
  check "act -l -W lint.yml lists the lint job (proves act can parse this repo's workflows)" 0
else
  check "act -l -W lint.yml lists the lint job" 1 "output=[${ACT_LIST_OUT}]"
fi

# ---------------------------------------------------------------------------
# 8. FOUND-05's actual requirement: the lint workflow genuinely runs to
#    completion under act. Ensures the custom local image .actrc points at
#    exists first (see .actrc's own comment — the stock medium image lacks
#    `ruby`, which this job's YAML check depends on).
# ---------------------------------------------------------------------------
if ! docker image inspect athena/act-ubuntu-latest:act-latest >/dev/null 2>&1; then
  docker build -t athena/act-ubuntu-latest:act-latest - >/dev/null 2>&1 <<'DOCKERFILE'
FROM catthehacker/ubuntu:act-latest
RUN apt-get update && apt-get install -y --no-install-recommends ruby \
    && rm -rf /var/lib/apt/lists/*
DOCKERFILE
fi

ACT_RUN_OUT="$(cd "${REPO_ROOT}" && act push -W .github/workflows/lint.yml 2>&1)"
ACT_RUN_RC=$?
if [ "${ACT_RUN_RC}" -eq 0 ]; then
  check "act push -W lint.yml exits 0 (FOUND-05)" 0
else
  check "act push -W lint.yml exits 0 (FOUND-05)" 1 \
    "rc=${ACT_RUN_RC} (tail) $(printf '%s' "${ACT_RUN_OUT}" | tail -5 | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
printf '[verify-runner] %s passed, %s failed, %s total.\n' \
  "${PASS_COUNT}" "${FAIL_COUNT}" "$((PASS_COUNT + FAIL_COUNT))"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
