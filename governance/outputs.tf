# outputs.tf — repository identifiers and team IDs consumed by later plans.
#
# Plan 05's environments.tf/protections.tf/actions-security.tf reads the team
# ID outputs for bypass_actors/reviewers blocks; anything scripting a git
# remote (Task 2 of this plan, and any later automation) reads the clone URL
# outputs instead of hardcoding "https://github.com/AuraBit/<repo>.git".

output "org_login" {
  description = "The GitHub organisation login actually in use for the estate."
  value       = var.github_owner
}

output "repository_full_names" {
  description = "Full names (owner/repo) of the four estate repositories."
  value = {
    athena_app    = github_repository.athena_app.full_name
    athena_infra  = github_repository.athena_infra.full_name
    athena_gitops = github_repository.athena_gitops.full_name
    athena_docs   = github_repository.athena_docs.full_name
  }
}

output "repository_clone_urls" {
  description = "HTTPS clone URLs for the four estate repositories, for attaching local `origin` remotes."
  value = {
    athena_app    = github_repository.athena_app.http_clone_url
    athena_infra  = github_repository.athena_infra.http_clone_url
    athena_gitops = github_repository.athena_gitops.http_clone_url
    athena_docs   = github_repository.athena_docs.http_clone_url
  }
}

output "team_ids" {
  description = "Numeric GitHub team IDs, keyed by team slug — consumed by Plan 05's ruleset bypass_actors and Environment reviewers blocks."
  value = {
    team_platform   = github_team.team_platform.id
    team_storefront = github_team.team_storefront.id
    team_commerce   = github_team.team_commerce.id
    team_catalog    = github_team.team_catalog.id
    team_comms      = github_team.team_comms.id
    team_media      = github_team.team_media.id
  }
}

output "team_slugs" {
  description = "Team slugs, keyed the same way as team_ids, for scripts/verify-governance.sh and any gh api verification calls."
  value = {
    team_platform   = github_team.team_platform.slug
    team_storefront = github_team.team_storefront.slug
    team_commerce   = github_team.team_commerce.slug
    team_catalog    = github_team.team_catalog.slug
    team_comms      = github_team.team_comms.slug
    team_media      = github_team.team_media.slug
  }
}
