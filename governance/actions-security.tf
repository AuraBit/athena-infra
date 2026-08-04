# actions-security.tf — the org-wide Actions security baseline (D-08,
# CI-06). This file owns exactly one resource type this stack hasn't
# created yet: github_actions_organization_permissions (the
# enabled-repositories / allowed-actions ALLOWLIST resource). It is
# deliberately distinct from org.tf's
# github_actions_organization_workflow_permissions (the GITHUB_TOKEN
# default-permissions + PR-approval-toggle resource, already created in
# Plan 04) — see org.tf's own header comment for that boundary.

resource "github_actions_organization_permissions" "this" {
  enabled_repositories = "all"
  allowed_actions      = "selected"

  # GitHub-native, org-wide enforcement that every action/reusable workflow
  # reference is SHA-pinned — the same control this stack's four lint.yml
  # workflows already assert via grep (Task 1), applied here as a second,
  # independent layer that GitHub itself rejects a violation against,
  # rather than relying solely on this repo's own CI to catch it (T-01-22).
  sha_pinning_required = true

  allowed_actions_config {
    github_owned_allowed = true
    verified_allowed     = true
    # Every named third-party action this estate actually uses, beyond
    # GitHub-owned/verified-creator actions covered by the two flags above.
    # An action not GitHub-owned, not from a verified creator, and not
    # named here is rejected org-wide, which is the point (D-08) --
    # confirmed the hard way in Plan 02-04: terraform-core-network.yml's
    # first run against a real PR reported `startup_failure` with zero
    # jobs scheduled, before this list named the two non-verified-creator
    # actions it references. hashicorp/setup-terraform is not added here
    # explicitly -- HashiCorp carries GitHub's verified-creator badge, so
    # `verified_allowed = true` already covers it; the plan/apply job logs
    # confirm this (no rejection for that action specifically).
    patterns_allowed = [
      "dorny/paths-filter@*",                     # Plan 02-04 -- terraform-core-network.yml's detect-changes job
      "marocchino/sticky-pull-request-comment@*", # Plan 02-04 -- terraform-core-network.yml's plan job (D-02 sticky comment)
    ]
  }
}

# --- Fork pull request approval — a genuine, confirmed API gap, not a
#     Terraform-provider gap (D-10's escape-hatch procedure, extended) -----
#
# D-08/CI-06 requires: "Require approval for fork pull requests from all
# outside collaborators, not just first-time contributors" — the org-level
# half of CI-06 (job-level self-hosted-runner restriction is Plan 06's
# half).
#
# This setting ("Fork pull request workflows from outside collaborators",
# GitHub Settings -> Actions -> General, per repository) has **no REST or
# GraphQL API surface at all** — this was verified directly against the
# live API this plan, not assumed:
#   - Every plausible REST path was probed directly against both org- and
#     repo-scoped endpoints (`/orgs/<org>/actions/permissions/*`,
#     `/repos/<org>/<repo>/actions/permissions/*` with every fork-pr-shaped
#     path variant) — each returned a generic 404 with
#     `documentation_url: https://docs.github.com/rest` (GitHub's signature
#     for "route does not exist," distinct from the specific
#     `.../rest/actions/permissions#...` doc-linked 404/409 responses the
#     *real* neighbouring endpoints return).
#   - GraphQL schema introspection on both the `Organization` and
#     `Repository` types was queried for every field containing "fork" —
#     none relate to workflow-approval policy.
#
# Because no API exists (not "the integrations/github provider doesn't
# expose it" — there is nothing for any provider, or any `gh api` script,
# to call), this is NOT closable by Terraform, by a companion script, or by
# any other form of automation available to this stack. It is a genuine,
# UI-only manual step, structurally identical to D-09's org/bot-account/
# repo bootstrap steps — not a shortcut avoided, a control that does not
# have a programmatic surface as of this plan's execution (2026-08-03).
#
# Recorded here per D-10's escape-hatch procedure (name the gap explicitly,
# do not work around it silently) and repeated in
# docs/runbooks/github-bootstrap.md's provider-coverage-gaps section and
# this plan's SUMMARY.md "User Setup Required" section, with the exact
# manual steps to complete it on all four repositories:
#
#   For each of athena-app, athena-infra, athena-gitops, athena-docs:
#     Settings -> Actions -> General -> "Fork pull request workflows from
#     outside collaborators" -> select "Require approval for all outside
#     collaborators" -> Save.
#
# scripts/verify-governance.sh (Task 3) states plainly that this one
# specific item cannot be asserted from the API and must be confirmed by a
# human walking the repo Settings UI — it does not fabricate a passing
# check for a control with no readable API surface.
