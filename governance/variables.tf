# variables.tf — governance stack inputs.
#
# github_owner default: NOTE this deliberately diverges from CONTEXT.md D-06's
# originally-assumed org login "athena-platform". That login was found live
# (during this plan's execution) to already belong to an unrelated third
# party, so the estate's org is "AuraBit" instead — created fresh under the
# developer's own account. The default below reflects that resolved reality,
# not the plan's original assumption; every other decision in D-05/D-06
# (free org, not personal account; team-based CODEOWNERS; org-scoped
# runner/secrets) is unaffected by the name change.

variable "github_owner" {
  description = <<-EOT
    The GitHub organisation login that hosts the estate. Defaults to
    "AuraBit" — the org actually created for this project (D-05/D-06); the
    plan's originally-assumed login "athena-platform" was unavailable
    (already owned by an unrelated GitHub account). Override only if the org
    login changes again (e.g. a further fallback suffix).
  EOT
  type        = string
  default     = "AuraBit"
}

variable "github_token" {
  description = <<-EOT
    A GitHub PAT authenticating as the athena-ci-bot machine account (D-03),
    scoped with org admin + repo + workflow permissions. Terraform uses this
    identity to manage the org, teams, repos, and (in Plan 05) branch
    protection/Environments — never the developer's own personal token.
    Sourced from estate/athena-infra/.governance.env (git-ignored), never
    hardcoded and never printed in plan/apply output.
  EOT
  type        = string
  sensitive   = true
}

variable "developer_username" {
  description = <<-EOT
    The human developer's GitHub login, added as a member of every team
    (team-platform plus the five domain teams) — a solo developer simulating
    a platform org is a member of all of them, which is the honest modelling
    per D-07.
  EOT
  type        = string
  default     = "YahiaEng"
}
