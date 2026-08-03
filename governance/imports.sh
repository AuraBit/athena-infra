#!/usr/bin/env bash
# imports.sh — bootstrap-then-import adoption (D-09, RESEARCH.md Pattern 3).
#
# The org, the athena-ci-bot machine account, and the athena-infra repository
# were created BY HAND, because no Terraform run can create the org it
# authenticates against (the chicken-and-egg step). This script adopts the
# two Terraform-manageable objects among those (the org's settings resource
# and the athena-infra repository resource) into this stack's state via
# `terraform import`, rather than letting a bare `terraform apply` attempt to
# recreate them.
#
# Idempotent: safe to re-run. Each import is skipped if the resource address
# is already present in state. Run this from the governance/ directory (or
# pass GOV_DIR) after `terraform init`.
#
# Success condition: the `terraform plan` this script prints at the end must
# report NO CHANGES for both imported resources. An import that leaves a diff
# means the code does not describe what actually exists — the exact failure
# mode this step guards against.
#
# Required env (see estate/athena-infra/.governance.env, git-ignored):
#   GITHUB_TOKEN  — PAT authenticating as athena-ci-bot, org admin + repo scopes
#   GITHUB_OWNER  — the org login (e.g. AuraBit)

set -euo pipefail

GOV_DIR="${GOV_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
cd "$GOV_DIR"

: "${GITHUB_TOKEN:?GITHUB_TOKEN must be exported (see .governance.env)}"
: "${GITHUB_OWNER:?GITHUB_OWNER must be exported (see .governance.env)}"

echo "==> imports.sh: adopting hand-bootstrapped resources for org '${GITHUB_OWNER}'"

already_imported() {
  # Returns 0 (true) if the given resource address is already in state.
  terraform state list 2>/dev/null | grep -qxF "$1"
}

# --- 1. github_organization_settings.this -------------------------------
# Import ID is the org's numeric ID, not its login (per provider docs) —
# fetched live rather than hardcoded, so this script tolerates a future
# org-login change without editing.
if already_imported "github_organization_settings.this"; then
  echo "==> github_organization_settings.this already in state — skipping import"
else
  echo "==> Fetching numeric org ID for '${GITHUB_OWNER}'..."
  ORG_ID="$(curl -sS -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    "https://api.github.com/orgs/${GITHUB_OWNER}" | grep -o '"id": *[0-9]*' | head -1 | grep -o '[0-9]*')"
  if [ -z "$ORG_ID" ]; then
    echo "FATAL: could not resolve numeric org ID for '${GITHUB_OWNER}' — is GITHUB_TOKEN valid and does the org exist?" >&2
    exit 1
  fi
  echo "==> Importing github_organization_settings.this (org id ${ORG_ID})..."
  terraform import github_organization_settings.this "${ORG_ID}"
fi

# --- 2. github_repository.athena_infra -----------------------------------
if already_imported "github_repository.athena_infra"; then
  echo "==> github_repository.athena_infra already in state — skipping import"
else
  echo "==> Importing github_repository.athena_infra (repo name: athena-infra)..."
  terraform import github_repository.athena_infra athena-infra
fi

echo ""
echo "==> Import pass complete. Run this next and confirm it reports NO CHANGES"
echo "    for the two imported resources (a diff means the code doesn't match"
echo "    what was hand-bootstrapped, and must be fixed before apply):"
echo ""
echo "    terraform -chdir=${GOV_DIR} plan -detailed-exitcode"
echo ""
