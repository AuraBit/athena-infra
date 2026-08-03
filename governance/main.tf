# Governance Terraform stack — manages the GitHub org itself as infrastructure.
#
# State locality (D-10): this stack's state (governance/terraform.tfstate) is
# deliberately kept LOCAL — not the S3-lockfile pattern the Phase 2+ AWS
# stacks use. The reasoning is a state-locality principle, not an oversight:
#
#   - This state tracks a real, persistent GitHub organisation that outlives
#     every local restart. Losing this state would mean losing track of
#     infrastructure that still exists (the org, its repos, its teams).
#   - Phase 2+ AWS-stack state lives in LocalStack S3 instead, because
#     LocalStack's free Hobby tier is itself ephemeral — a restart wipes both
#     the emulated AWS resources AND their Terraform state together, which is
#     the *coherent* behaviour for that tier (no drift between "what
#     Terraform thinks exists" and "what's actually running"; recovery is the
#     documented world-rebuild runbook, not a state restore).
#
# In short: local-vs-remote state here tracks whether the thing being
# governed is itself persistent (GitHub, yes) or ephemeral (free-tier
# LocalStack, no) — not a stylistic choice. Plan 07 promotes this contrast to
# a standalone ADR.
#
# Plan 05 extends this same module with protections.tf, environments.tf, and
# actions-security.tf (branch rulesets, GitHub Environments + reviewers, and
# the org-level Actions permissions/allowlist) — this file only wires the
# provider and the (deliberately) local backend.

terraform {
  required_version = ">= 1.11"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
  }

  # Explicitly local backend — see the state-locality note above. No S3
  # backend block here; that divergence from Phase 2+ is the point.
  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "github" {
  owner = var.github_owner
  token = var.github_token
}
