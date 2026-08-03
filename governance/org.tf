# org.tf — organisation-level profile and safety-relevant defaults.
#
# Two distinct GitHub-provider resources are involved here, and only one of
# them belongs to this file:
#
#   - github_organization_settings.this (below): profile fields, default
#     repository permission, and whether members can create repos outside
#     Terraform.
#   - github_actions_organization_workflow_permissions.this (below): the
#     org-wide "can GitHub Actions create and approve pull requests" toggle
#     (T-01-16 — the control against a compromised workflow approving its
#     own malicious PR; this is the org-level half of D-03's design, where a
#     distinct bot *account* does the approving instead).
#
# github_actions_organization_permissions (the enabled-repositories /
# allowed-actions ALLOWLIST resource) is a THIRD, separate resource and is
# explicitly NOT created here — that belongs to Plan 05's actions-security.tf
# per this plan's action block.

resource "github_organization_settings" "this" {
  billing_email = "eng-yahia-tarek@outlook.com"
  name          = "AuraBit"
  # GitHub caps org descriptions at 160 characters — see athena-docs for the
  # full "Athena" project story this org hosts.
  description = "Athena — Production-Grade DevOps Estate Mockup. A studied, broken, fixed, and explained senior DevOps interview-prep CI/CD estate."

  has_organization_projects = true
  has_repository_projects   = true

  # Access is granted explicitly through team assignments (teams.tf/repos.tf),
  # not inherited by default (T-01-20).
  default_repository_permission   = "read"
  members_can_create_repositories = false

  # No sub-visibility toggles matter once repository creation itself is
  # disabled above, but set them false for defense-in-depth / explicitness.
  members_can_create_public_repositories   = false
  members_can_create_private_repositories  = false
  members_can_create_internal_repositories = false

  members_can_fork_private_repositories = false
  web_commit_signoff_required           = false
}

resource "github_actions_organization_workflow_permissions" "this" {
  organization_slug = var.github_owner

  # Jobs get a read-only GITHUB_TOKEN by default; workflows elevate scope
  # explicitly per-job via `permissions:` blocks (D-08).
  default_workflow_permissions = "read"

  # T-01-16: disabled so a compromised workflow token cannot approve its own
  # malicious PR. athena-ci-bot (a distinct machine-account identity, not a
  # workflow token) performs PR approvals instead — this is precisely why
  # D-03 requires a separate bot account rather than relying on Actions'
  # own approval capability.
  can_approve_pull_request_reviews = false
}
