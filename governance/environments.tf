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

# --- athena-infra ------------------------------------------------------------
#
# Plan 02-06 (D-31, D-13, REPO-04): six Environments, not three. The apply
# job in .github/workflows/terraform-core-network.yml binds
# `environment: ${{ matrix.env }}` where matrix.env is dev/stg/prod, so
# infra_dev/infra_stg/infra_prod below are what actually pauses that job.
# The plan job declares NO `environment:` at all (a gated Environment would
# pause every stg/prod plan on every pull request, defeating the review
# loop D-31 is not gating) -- but it still needs somewhere to read its
# non-secret AWS configuration from in a future OIDC world, which is what
# the three *-plan Environments below are for (see environment-variables.tf
# for that half).
#
# DELIBERATE CARVE-OUT FROM THE app/gitops PATTERN ABOVE: athena-app and
# athena-gitops gate stg/prod on `local.env_reviewer_team_ids`
# (team-platform). athena-infra's stg and prod reviewer is the human
# developer specifically -- var.developer_user_id, a `users` entry, not a
# `teams` entry. The reason is D-03/D-31: athena-ci-bot already holds the
# pull-request-approval role on every repo in this estate (protections.tf's
# bypass_actors), and letting that same identity also authorise the
# `terraform apply` that changes stg or prod would collapse two genuinely
# different decisions -- "is this diff correct" and "is now the right time
# to apply it to a real environment" -- into one actor's single click.
# Reviewing the code and authorising the change stay separate controls
# here, and an estate that models them with different actors can actually
# say so in an interview, rather than asserting it and pointing at a single
# green checkmark that means both things at once.
resource "github_repository_environment" "infra_dev" {
  environment = "dev"
  repository  = github_repository.athena_infra.name
  # No reviewers, no wait_timer, and deliberately no deployment_branch_policy
  # block either -- same zero-protection-rules reasoning as app_dev/gitops_dev
  # above: dev's protection_rules list must be empty, not just its
  # required-reviewers subset, so `apply (dev)` runs unattended.
}

resource "github_repository_environment" "infra_stg" {
  environment = "stg"
  repository  = github_repository.athena_infra.name

  reviewers {
    users = [var.developer_user_id]
  }

  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}

resource "github_repository_environment" "infra_prod" {
  environment = "prod"
  repository  = github_repository.athena_infra.name

  reviewers {
    users = [var.developer_user_id]
  }

  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}

# infra_dev_plan / infra_stg_plan / infra_prod_plan: the read-only
# counterparts the `plan` job would bind to in a future real-AWS OIDC swap.
# They carry NO reviewers and NO protection rules of any kind, even for
# stg-plan/prod-plan -- a gated Environment pauses every job that declares
# it, and the `plan` job runs on every pull request touching that env, not
# just the ones a human has already decided to promote. Gating it would
# make the review loop itself require an approval before a reviewer could
# see what they're approving, which is backwards.
#
# The split exists because it is also the shape real per-environment
# credential scoping takes: a read-only plan role and a read-write apply
# role are two different IAM identities in a real AWS account, never one.
# Splitting the Environment now, while the "credentials" are just
# LocalStack-namespacing literals (D-16), means the day this estate points
# at real AWS via OIDC, the swap is "point plan's Environment at a
# read-only role ARN, point apply's Environment at a read-write one" -- a
# configuration change to environment-variables.tf, not a restructuring of
# which Environment which job declares.
resource "github_repository_environment" "infra_dev_plan" {
  environment = "dev-plan"
  repository  = github_repository.athena_infra.name
}

resource "github_repository_environment" "infra_stg_plan" {
  environment = "stg-plan"
  repository  = github_repository.athena_infra.name
}

resource "github_repository_environment" "infra_prod_plan" {
  environment = "prod-plan"
  repository  = github_repository.athena_infra.name
}
