#!/usr/bin/env bash
# verify-governance.sh — REPO-02, REPO-03, REPO-04, CI-06 assertions for the
# governed estate (Plan 05).
#
# A ruleset that exists is not a ruleset that blocks — every check below
# asserts the live GitHub state from the outside (via `gh api` /
# `terraform plan`), never the .tf source alone, so a check here only
# passes if GitHub itself reports the control as active. The required
# status-check context is read out of each repo's own lint.yml at
# assertion time rather than hardcoded as the literal string "lint" — a
# mismatch between the ruleset's required check and the workflow's actual
# job id is the specific failure mode that makes `main` permanently
# unmergeable, and hardcoding the expected value here would make this
# script blind to exactly that failure.
#
# One control genuinely has no API surface to assert against (fork-PR
# approval for outside collaborators — see actions-security.tf's own
# comment for the live-verified evidence that no REST or GraphQL endpoint
# exists for it at all). That single item is reported as MANUAL, not
# fabricated as a PASS, and does not count toward FAIL_COUNT — the script
# does not lie about what it can prove.
#
# Deliberately not using `set -e` (mirrors verify-skeleton.sh /
# verify-localstack.sh): every fallible command is captured into a variable
# first so one failing check never aborts the ones after it;
# scripts/verify.sh (this script's dispatcher) is what turns any FAIL here
# into a non-zero process exit.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOV_DIR="${SCRIPT_DIR}/../governance"
REPOS=(athena-app athena-infra athena-gitops athena-docs)

# GITHUB_OWNER/GITHUB_TOKEN must already be exported (see
# docs/runbooks/github-bootstrap.md — `set -a; . estate/athena-infra/.governance.env; set +a`).
: "${GITHUB_OWNER:?GITHUB_OWNER must be exported — see docs/runbooks/github-bootstrap.md}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN must be exported — see docs/runbooks/github-bootstrap.md}"

PASS_COUNT=0
FAIL_COUNT=0
MANUAL_COUNT=0

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

manual() {
  local name="$1" reason="$2"
  printf '\033[33mMANUAL\033[0m %s\n' "${name}"
  printf '       reason: %s\n' "${reason}"
  MANUAL_COUNT=$((MANUAL_COUNT + 1))
}

gh_api() { gh api "$@" 2>&1; }

# Extracts the sole job id from a repo's lint.yml (jobs: <one key>: ...).
lint_job_id() {
  local repo="$1"
  python3 - "${SCRIPT_DIR}/../../${repo}/.github/workflows/lint.yml" <<'PY' 2>/dev/null
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f)
    print(next(iter(data["jobs"].keys())))
except Exception:
    pass
PY
}

# ---------------------------------------------------------------------------
# 1. Governance stack has no drift
# ---------------------------------------------------------------------------
PLAN_OUT="$(cd "${GOV_DIR}" && TF_VAR_github_token="${GITHUB_TOKEN}" terraform plan -input=false -detailed-exitcode 2>&1)"
PLAN_EXIT=$?
if [ "${PLAN_EXIT}" -eq 0 ]; then
  check "governance stack: terraform plan -detailed-exitcode reports no changes" 0
else
  check "governance stack: terraform plan -detailed-exitcode reports no changes" 1 \
    "exit=${PLAN_EXIT} (tail) $(printf '%s' "${PLAN_OUT}" | tail -5 | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# 2. Per-repo: active protect-main ruleset, pull_request + required_status_checks
#    rule types present, required check context matches lint.yml's job id
#    (read live, not hardcoded). Also covers the "Edge, empty" case: every
#    repo's ruleset reports active regardless of PR history.
# ---------------------------------------------------------------------------
MERGE_QUEUE_REPOS=()
for repo in "${REPOS[@]}"; do
  ENFORCEMENT="$(gh_api "/repos/${GITHUB_OWNER}/${repo}/rulesets" --jq '.[] | select(.name=="protect-main") | .enforcement')"
  RULE_TYPES="$(gh_api "/repos/${GITHUB_OWNER}/${repo}/rules/branches/main" --jq '[.[].type] | sort | join(",")')"
  EXPECTED_CONTEXT="$(lint_job_id "${repo}")"
  ACTUAL_CONTEXT="$(gh_api "/repos/${GITHUB_OWNER}/${repo}/rules/branches/main" --jq '[.[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context] | join(",")')"

  if [ "${ENFORCEMENT}" = "active" ]; then
    check "${repo}: protect-main ruleset is active (holds with zero PRs too)" 0
  else
    check "${repo}: protect-main ruleset is active (holds with zero PRs too)" 1 \
      "enforcement=[${ENFORCEMENT}]"
  fi

  case "${RULE_TYPES}" in
    *pull_request*required_status_checks* | *required_status_checks*pull_request*)
      check "${repo}: ruleset requires pull_request AND required_status_checks" 0
      ;;
    *)
      check "${repo}: ruleset requires pull_request AND required_status_checks" 1 \
        "rule_types=[${RULE_TYPES}]"
      ;;
  esac

  # "contains", not "equals": athena-infra (Plan 02-06, D-32) is the one
  # repo whose required-check set grows to two entries (lint + the
  # terraform-core-network.yml aggregator, asserted separately in section
  # 10 below) -- for the other three repos, whose set has exactly one
  # entry, "contains" and "equals" are the same assertion.
  if [ -n "${EXPECTED_CONTEXT}" ] && printf '%s' "${ACTUAL_CONTEXT}" | tr ',' '\n' | grep -qx "${EXPECTED_CONTEXT}"; then
    check "${repo}: required check context includes lint.yml's job id ('${EXPECTED_CONTEXT}')" 0
  else
    check "${repo}: required check context includes lint.yml's job id" 1 \
      "expected=[${EXPECTED_CONTEXT}] actual=[${ACTUAL_CONTEXT}]"
  fi

  if printf '%s' "${RULE_TYPES}" | grep -q 'merge_queue'; then
    MERGE_QUEUE_REPOS+=("${repo}")
  fi
done

# ---------------------------------------------------------------------------
# 3. Exactly one repo (athena-app) has a merge-queue rule
# ---------------------------------------------------------------------------
if [ "${#MERGE_QUEUE_REPOS[@]}" -eq 1 ] && [ "${MERGE_QUEUE_REPOS[0]}" = "athena-app" ]; then
  check "exactly one repo (athena-app) carries a merge-queue rule" 0
else
  check "exactly one repo (athena-app) carries a merge-queue rule" 1 \
    "repos_with_merge_queue=[${MERGE_QUEUE_REPOS[*]:-none}]"
fi

# ---------------------------------------------------------------------------
# 4. Edge, adjacency: athena-app's required_approving_review_count is
#    exactly 1 and code-owner review is required
# ---------------------------------------------------------------------------
APP_PR_PARAMS="$(gh_api "/repos/${GITHUB_OWNER}/athena-app/rules/branches/main" --jq '.[] | select(.type=="pull_request") | .parameters')"
APP_REVIEW_COUNT="$(printf '%s' "${APP_PR_PARAMS}" | jq -r '.required_approving_review_count')"
APP_CODEOWNER="$(printf '%s' "${APP_PR_PARAMS}" | jq -r '.require_code_owner_review')"
if [ "${APP_REVIEW_COUNT}" = "1" ] && [ "${APP_CODEOWNER}" = "true" ]; then
  check "athena-app: required_approving_review_count==1 and require_code_owner_review==true" 0
else
  check "athena-app: required_approving_review_count==1 and require_code_owner_review==true" 1 \
    "required_approving_review_count=[${APP_REVIEW_COUNT}] require_code_owner_review=[${APP_CODEOWNER}]"
fi

# ---------------------------------------------------------------------------
# 5. athena-app Environments are exactly dev, stg, prod; stg/prod carry
#    required_reviewers + branch_policy protection rules; dev carries none
# ---------------------------------------------------------------------------
ENV_NAMES="$(gh_api "/repos/${GITHUB_OWNER}/athena-app/environments" --jq '[.environments[].name] | sort | join(",")')"
if [ "${ENV_NAMES}" = "dev,prod,stg" ]; then
  check "athena-app environments are exactly dev, prod, stg" 0
else
  check "athena-app environments are exactly dev, prod, stg" 1 "observed=[${ENV_NAMES}]"
fi

for env in stg prod; do
  RULE_TYPES="$(gh_api "/repos/${GITHUB_OWNER}/athena-app/environments/${env}" --jq '[.protection_rules[].type] | sort | join(",")')"
  case "${RULE_TYPES}" in
    *required_reviewers*branch_policy* | *branch_policy*required_reviewers*)
      check "athena-app/${env}: required_reviewers + protected-branch deployment policy present" 0
      ;;
    *)
      check "athena-app/${env}: required_reviewers + protected-branch deployment policy present" 1 \
        "rule_types=[${RULE_TYPES}]"
      ;;
  esac
done

DEV_RULE_COUNT="$(gh_api "/repos/${GITHUB_OWNER}/athena-app/environments/dev" --jq '.protection_rules | length')"
if [ "${DEV_RULE_COUNT}" = "0" ]; then
  check "athena-app/dev: zero protection rules (automatic promotion, no gate)" 0
else
  check "athena-app/dev: zero protection rules (automatic promotion, no gate)" 1 \
    "protection_rules_count=[${DEV_RULE_COUNT}]"
fi

# ---------------------------------------------------------------------------
# 6. Org Actions policy: allowlisted, read-only default token, cannot
#    approve PRs. Fork-PR approval has no API surface (see
#    actions-security.tf) and is reported MANUAL, not fabricated.
# ---------------------------------------------------------------------------
ALLOWED_ACTIONS="$(gh_api "/orgs/${GITHUB_OWNER}/actions/permissions" --jq '.allowed_actions')"
if [ "${ALLOWED_ACTIONS}" = "selected" ]; then
  check "org Actions policy: allowed_actions == selected" 0
else
  check "org Actions policy: allowed_actions == selected" 1 "observed=[${ALLOWED_ACTIONS}]"
fi

DEFAULT_PERMS="$(gh_api "/orgs/${GITHUB_OWNER}/actions/permissions/workflow" --jq '.default_workflow_permissions')"
if [ "${DEFAULT_PERMS}" = "read" ]; then
  check "org Actions policy: default_workflow_permissions == read" 0
else
  check "org Actions policy: default_workflow_permissions == read" 1 "observed=[${DEFAULT_PERMS}]"
fi

CAN_APPROVE="$(gh_api "/orgs/${GITHUB_OWNER}/actions/permissions/workflow" --jq '.can_approve_pull_request_reviews')"
if [ "${CAN_APPROVE}" = "false" ]; then
  check "org Actions policy: Actions cannot approve pull requests" 0
else
  check "org Actions policy: Actions cannot approve pull requests" 1 "observed=[${CAN_APPROVE}]"
fi

manual "org Actions policy: fork PRs from all outside collaborators require approval" \
  "no REST or GraphQL API exists for this setting (verified live, see actions-security.tf) — confirm manually via each repo's Settings -> Actions -> General page"

# ---------------------------------------------------------------------------
# 7. Every non-local `uses:` reference across all four workflow files
#    terminates in a full-length lowercase hex commit SHA
# ---------------------------------------------------------------------------
UNPINNED_COUNT=0
UNPINNED_LIST=()
for repo in "${REPOS[@]}"; do
  WF="${SCRIPT_DIR}/../../${repo}/.github/workflows/lint.yml"
  if [ -f "${WF}" ]; then
    while IFS= read -r line; do
      [ -z "${line}" ] && continue
      UNPINNED_COUNT=$((UNPINNED_COUNT + 1))
      UNPINNED_LIST+=("${repo}:${line}")
    done < <(grep -oE 'uses: *[^ ]+' "${WF}" | sed 's/^uses: *//' | grep -v '^\./' | grep -vE '@[0-9a-f]{40}$' || true)
  fi
done
if [ "${UNPINNED_COUNT}" -eq 0 ]; then
  check "all non-local 'uses:' references across all four workflows are SHA-pinned" 0
else
  check "all non-local 'uses:' references across all four workflows are SHA-pinned" 1 \
    "unpinned=[${UNPINNED_LIST[*]}]"
fi

# ---------------------------------------------------------------------------
# 8. GitHub reports zero CODEOWNERS errors for athena-app
# ---------------------------------------------------------------------------
# NOTE: this endpoint 404s unless `ref` is given as a fully-qualified
# refs/heads/<branch> — "main" alone 404s even though the file exists and is
# valid (an undocumented quirk, verified live this plan; see
# docs/runbooks/github-bootstrap.md's provider-coverage-gaps section).
CODEOWNERS_ERR_COUNT="$(gh_api "/repos/${GITHUB_OWNER}/athena-app/codeowners/errors?ref=refs/heads/main" --jq '.errors | length')"
if [ "${CODEOWNERS_ERR_COUNT}" = "0" ]; then
  check "athena-app: zero CODEOWNERS errors reported by GitHub" 0
else
  check "athena-app: zero CODEOWNERS errors reported by GitHub" 1 \
    "errors_count=[${CODEOWNERS_ERR_COUNT}]"
fi

# ---------------------------------------------------------------------------
# 9. athena-infra Environments (D-31, D-13, Plan 02-06): exactly six, dev
#    and the three -plan variants carry zero protection rules, stg/prod
#    carry a required-reviewers rule naming the human developer (not the
#    bot), and every one of the six carries exactly the five expected
#    Actions variable names. The expected developer login and the expected
#    variable-key set are both read from `terraform output` (governance
#    stack), never retyped as a second hardcoded literal in this script.
# ---------------------------------------------------------------------------
TF_OUTPUT_JSON="$(cd "${GOV_DIR}" && TF_VAR_github_token="${GITHUB_TOKEN}" terraform output -json 2>/dev/null)"
DEV_LOGIN="$(printf '%s' "${TF_OUTPUT_JSON}" | jq -r '.developer_username.value // empty')"
EXPECTED_VAR_KEYS_JSON="$(printf '%s' "${TF_OUTPUT_JSON}" | jq -c '.infra_environment_variable_keys.value // {}')"

INFRA_ENV_NAMES="$(gh_api "/repos/${GITHUB_OWNER}/athena-infra/environments" --jq '[.environments[].name] | sort | join(",")')"
if [ "${INFRA_ENV_NAMES}" = "dev,dev-plan,prod,prod-plan,stg,stg-plan" ]; then
  check "athena-infra environments are exactly the six D-31/D-13 names" 0
else
  check "athena-infra environments are exactly the six D-31/D-13 names" 1 "observed=[${INFRA_ENV_NAMES}]"
fi

for env in dev dev-plan stg-plan prod-plan; do
  RULE_COUNT="$(gh_api "/repos/${GITHUB_OWNER}/athena-infra/environments/${env}" --jq '.protection_rules | length')"
  if [ "${RULE_COUNT}" = "0" ]; then
    check "athena-infra/${env}: zero protection rules" 0
  else
    check "athena-infra/${env}: zero protection rules" 1 "protection_rules_count=[${RULE_COUNT}]"
  fi
done

for env in stg prod; do
  REVIEWER_LOGINS="$(gh_api "/repos/${GITHUB_OWNER}/athena-infra/environments/${env}" --jq '[.protection_rules[] | select(.type=="required_reviewers") | .reviewers[].reviewer.login] | join(",")')"
  if [ -n "${DEV_LOGIN}" ] && printf '%s' "${REVIEWER_LOGINS}" | grep -qx "${DEV_LOGIN}" && ! printf '%s' "${REVIEWER_LOGINS}" | grep -q "athena-ci-bot"; then
    check "athena-infra/${env}: required reviewer is the human developer, not the bot (D-31)" 0
  else
    check "athena-infra/${env}: required reviewer is the human developer, not the bot (D-31)" 1 \
      "expected_login=[${DEV_LOGIN}] observed=[${REVIEWER_LOGINS}]"
  fi
done

for env in dev dev-plan stg stg-plan prod prod-plan; do
  EXPECTED_KEYS="$(printf '%s' "${EXPECTED_VAR_KEYS_JSON}" | jq -r --arg e "${env}" '.[$e] // [] | sort | join(",")')"
  ACTUAL_KEYS="$(gh_api "/repos/${GITHUB_OWNER}/athena-infra/environments/${env}/variables" --jq '[.variables[].name] | sort | join(",")')"
  if [ -n "${EXPECTED_KEYS}" ] && [ "${ACTUAL_KEYS}" = "${EXPECTED_KEYS}" ]; then
    check "athena-infra/${env}: carries exactly the expected Actions variable keys" 0
  else
    check "athena-infra/${env}: carries exactly the expected Actions variable keys" 1 \
      "expected=[${EXPECTED_KEYS}] actual=[${ACTUAL_KEYS}]"
  fi
done

# ---------------------------------------------------------------------------
# 10. athena-infra's main ruleset requires the aggregator check by its exact
#     reported name (D-32). The expected context is extracted from
#     terraform-core-network.yml itself, not typed a second time here: the
#     aggregator job is identified structurally (needs exactly
#     [detect-changes, static, plan] and `if: always()`, matching that
#     job's own header comment), so a rename of the job in the workflow
#     changes what this script expects instead of silently going stale.
# ---------------------------------------------------------------------------
aggregator_job_id() {
  python3 - "${SCRIPT_DIR}/../.github/workflows/terraform-core-network.yml" <<'PY' 2>/dev/null
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f)
    for job_id, job in data["jobs"].items():
        needs = job.get("needs", [])
        if isinstance(needs, str):
            needs = [needs]
        if sorted(needs) == sorted(["detect-changes", "static", "plan"]) and job.get("if") == "always()":
            print(job_id)
            break
except Exception:
    pass
PY
}

EXPECTED_AGGREGATOR="$(aggregator_job_id)"
INFRA_REQUIRED_CONTEXTS="$(gh_api "/repos/${GITHUB_OWNER}/athena-infra/rules/branches/main" --jq '[.[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context] | sort | join(",")')"
if [ -n "${EXPECTED_AGGREGATOR}" ] && printf '%s' "${INFRA_REQUIRED_CONTEXTS}" | tr ',' '\n' | grep -qx "${EXPECTED_AGGREGATOR}"; then
  check "athena-infra: main ruleset requires the aggregator check ('${EXPECTED_AGGREGATOR}', extracted from the workflow)" 0
else
  check "athena-infra: main ruleset requires the aggregator check (extracted from the workflow)" 1 \
    "expected=[${EXPECTED_AGGREGATOR}] required_contexts=[${INFRA_REQUIRED_CONTEXTS}]"
fi

if printf '%s' "${INFRA_REQUIRED_CONTEXTS}" | tr ',' '\n' | grep -qx "lint"; then
  check "athena-infra: main ruleset still requires 'lint' alongside the aggregator" 0
else
  check "athena-infra: main ruleset still requires 'lint' alongside the aggregator" 1 \
    "required_contexts=[${INFRA_REQUIRED_CONTEXTS}]"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
printf '[verify-governance] %s passed, %s failed, %s manual, %s total.\n' \
  "${PASS_COUNT}" "${FAIL_COUNT}" "${MANUAL_COUNT}" "$((PASS_COUNT + FAIL_COUNT))"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
