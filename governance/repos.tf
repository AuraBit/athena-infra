# repos.tf — the four estate repositories, as code.
#
# All four are `visibility = "public"` — public repos give unlimited free
# GitHub Actions minutes, which the project's $0 constraint depends on
# (REPO-01, D-18). `default_branch` is deliberately NOT set here: it's a
# deprecated github_repository argument (superseded by github_branch_default)
# and unnecessary — AuraBit's org-wide `default_repository_branch` is already
# "main" (confirmed live), and every local clone in estate/ is already on
# `main` (Plan 01's `git init` convention), so the branch pushed by Task 2
# becomes the real default with no extra resource needed.
#
# athena_infra is the one repository this stack ADOPTS BY IMPORT rather than
# creates from scratch (imports.sh) — it was hand-created empty per D-09's
# chicken-and-egg bootstrap step, because Terraform cannot manage the repo
# that holds its own governance code before that repo exists.

locals {
  repo_merge_settings = {
    allow_merge_commit     = true
    allow_squash_merge     = true
    allow_rebase_merge     = true
    delete_branch_on_merge = true
    has_issues             = true
    has_projects           = true
  }
}

resource "github_repository" "athena_app" {
  name        = "athena-app"
  description = "Athena application monorepo — a rebranded fork of Google's Online Boutique plus a custom Go 'media' service (Postgres, S3 uploads, Redis sessions). Path-filtered CI builds/tests/publishes only what changed."
  visibility  = "public"

  allow_merge_commit     = local.repo_merge_settings.allow_merge_commit
  allow_squash_merge     = local.repo_merge_settings.allow_squash_merge
  allow_rebase_merge     = local.repo_merge_settings.allow_rebase_merge
  delete_branch_on_merge = local.repo_merge_settings.delete_branch_on_merge
  has_issues             = local.repo_merge_settings.has_issues
  has_projects           = local.repo_merge_settings.has_projects
}

resource "github_repository" "athena_infra" {
  name        = "athena-infra"
  description = "Terraform lifecycle stacks (Core/Network, Data/Storage, Application/Compute) and the GitHub governance stack for the Athena estate — the repo this stack manages itself, adopted by import (D-09)."
  visibility  = "public"

  allow_merge_commit     = local.repo_merge_settings.allow_merge_commit
  allow_squash_merge     = local.repo_merge_settings.allow_squash_merge
  allow_rebase_merge     = local.repo_merge_settings.allow_rebase_merge
  delete_branch_on_merge = local.repo_merge_settings.delete_branch_on_merge
  has_issues             = local.repo_merge_settings.has_issues
  has_projects           = local.repo_merge_settings.has_projects

  lifecycle {
    prevent_destroy = true
  }
}

resource "github_repository" "athena_gitops" {
  name        = "athena-gitops"
  description = "ArgoCD-watched GitOps manifest repository for the Athena estate. Folder-per-environment (envs/dev, envs/stg, envs/prod) — never branch-per-env, a documented anti-pattern. CI commits image tags here; ArgoCD is the only thing that applies."
  visibility  = "public"

  allow_merge_commit     = local.repo_merge_settings.allow_merge_commit
  allow_squash_merge     = local.repo_merge_settings.allow_squash_merge
  allow_rebase_merge     = local.repo_merge_settings.allow_rebase_merge
  delete_branch_on_merge = local.repo_merge_settings.delete_branch_on_merge
  has_issues             = local.repo_merge_settings.has_issues
  has_projects           = local.repo_merge_settings.has_projects
}

resource "github_repository" "athena_docs" {
  name        = "athena-docs"
  description = "The Athena platform handbook — estate-level ADRs, architecture diagrams, per-tool interview study notes, runbooks, and drill logs. Carries no pipeline; extends the estate's documentation surface without adding a delivery path (D-18)."
  visibility  = "public"

  allow_merge_commit     = local.repo_merge_settings.allow_merge_commit
  allow_squash_merge     = local.repo_merge_settings.allow_squash_merge
  allow_rebase_merge     = local.repo_merge_settings.allow_rebase_merge
  delete_branch_on_merge = local.repo_merge_settings.delete_branch_on_merge
  has_issues             = local.repo_merge_settings.has_issues
  has_projects           = local.repo_merge_settings.has_projects
}

# Dependabot vulnerability alerts, via the non-deprecated dedicated resource
# (github_repository.vulnerability_alerts is deprecated by the provider in
# favour of this resource — using it directly here avoids a day-one
# deprecation warning on every plan/apply for the whole life of the stack).
resource "github_repository_vulnerability_alerts" "athena_app" {
  repository = github_repository.athena_app.name
  enabled    = true
}

resource "github_repository_vulnerability_alerts" "athena_infra" {
  repository = github_repository.athena_infra.name
  enabled    = true
}

resource "github_repository_vulnerability_alerts" "athena_gitops" {
  repository = github_repository.athena_gitops.name
  enabled    = true
}

resource "github_repository_vulnerability_alerts" "athena_docs" {
  repository = github_repository.athena_docs.name
  enabled    = true
}

# --- Team <-> repository grants -----------------------------------------
#
# team-platform owns .github/**, root configuration, and the infra/gitops/
# docs repositories (D-07) — "maintain" here (not "admin"): the team can
# manage issues/PRs/branch settings day-to-day without holding the
# destructive admin-only powers (delete repo, manage webhooks/secrets),
# which stay with the org-owner-authenticated Terraform identity.
resource "github_team_repository" "platform_infra" {
  team_id    = github_team.team_platform.id
  repository = github_repository.athena_infra.name
  permission = "maintain"
}

resource "github_team_repository" "platform_gitops" {
  team_id    = github_team.team_platform.id
  repository = github_repository.athena_gitops.name
  permission = "maintain"
}

resource "github_team_repository" "platform_docs" {
  team_id    = github_team.team_platform.id
  repository = github_repository.athena_docs.name
  permission = "maintain"
}

# Domain teams get push (write) on athena-app — the monorepo they all
# contribute service code into; CODEOWNERS (Plan 05) routes review by path.
resource "github_team_repository" "storefront_app" {
  team_id    = github_team.team_storefront.id
  repository = github_repository.athena_app.name
  permission = "push"
}

resource "github_team_repository" "commerce_app" {
  team_id    = github_team.team_commerce.id
  repository = github_repository.athena_app.name
  permission = "push"
}

resource "github_team_repository" "catalog_app" {
  team_id    = github_team.team_catalog.id
  repository = github_repository.athena_app.name
  permission = "push"
}

resource "github_team_repository" "comms_app" {
  team_id    = github_team.team_comms.id
  repository = github_repository.athena_app.name
  permission = "push"
}

resource "github_team_repository" "media_app" {
  team_id    = github_team.team_media.id
  repository = github_repository.athena_app.name
  permission = "push"
}

# team-platform also gets push on athena-app (it owns .github/** inside the
# monorepo, per D-07) — additive to, not a replacement for, the domain
# teams' grants above.
resource "github_team_repository" "platform_app" {
  team_id    = github_team.team_platform.id
  repository = github_repository.athena_app.name
  permission = "push"
}
