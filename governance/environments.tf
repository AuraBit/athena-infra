# environments.tf — dev/stg/prod GitHub Environments on athena-app and
# athena-gitops, with reviewer gating on stg/prod (REPO-04, D-04).
#
# D-04's design: the gate binds to the **promotion-commit job** — the
# workflow job that writes to envs/stg or envs/prod in athena-gitops (or,
# for athena-app, the job that triggers that write) declares the matching
# Environment and therefore pauses for a required reviewer. It does **not**
# bind to ArgoCD, whose auto-sync stays enabled in every environment so that
# Phase 3's manual-drift-revert demonstration keeps working. No such job
# exists yet — these Environments exist ahead of the code that will bind to
# them, same declare-before-the-code-exists pattern athena-app's CODEOWNERS
# uses for Phase 3's service directories. Phase 2 reuses this identical
# pattern to gate `terraform apply` jobs on athena-infra.
#
# dev has no reviewers and no wait timer: promotion into dev is automatic,
# by design — only stg and prod are gated (REPO-04's requirement is
# specifically about stg/prod, not dev).

locals {
  # Six team IDs are eligible for review generally, but D-04 specifically
  # assigns environment review to team-platform — the same team that owns
  # .github/** and the infra/gitops/docs repositories (D-07). One team
  # reviewing deploys to gated environments is the correct model for a
  # solo-developer simulation; per-domain-team environment reviewers would
  # invent organisational structure this estate doesn't have.
  env_reviewer_team_ids = [github_team.team_platform.id]
}

# --- athena-app --------------------------------------------------------------

resource "github_repository_environment" "app_dev" {
  environment = "dev"
  repository  = github_repository.athena_app.name
  # No reviewers, no wait_timer, and deliberately no deployment_branch_policy
  # block either — dev promotes automatically, with zero protection rules of
  # any kind (acceptance criterion: environments/dev's protection_rules list
  # is empty, not just its required_reviewers subset). Only stg/prod get the
  # protected-branch-origin restriction below.
}

resource "github_repository_environment" "app_stg" {
  environment = "stg"
  repository  = github_repository.athena_app.name

  reviewers {
    teams = local.env_reviewer_team_ids
  }

  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}

resource "github_repository_environment" "app_prod" {
  environment = "prod"
  repository  = github_repository.athena_app.name

  reviewers {
    teams = local.env_reviewer_team_ids
  }

  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}

# --- athena-gitops -------------------------------------------------------------
#
# The gitops repo carries the same three Environments — this is where the
# actual promotion-commit job (Phase 3) will bind, since athena-gitops is
# what physically holds envs/dev|stg|prod.

resource "github_repository_environment" "gitops_dev" {
  environment = "dev"
  repository  = github_repository.athena_gitops.name
  # No reviewers, no wait_timer, no deployment_branch_policy — same
  # zero-protection-rules reasoning as app_dev above.
}

resource "github_repository_environment" "gitops_stg" {
  environment = "stg"
  repository  = github_repository.athena_gitops.name

  reviewers {
    teams = local.env_reviewer_team_ids
  }

  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}

resource "github_repository_environment" "gitops_prod" {
  environment = "prod"
  repository  = github_repository.athena_gitops.name

  reviewers {
    teams = local.env_reviewer_team_ids
  }

  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}
