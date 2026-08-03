# teams.tf — six teams per D-07: team-platform plus five domain teams.
#
# Domain-team taxonomy (Claude's discretion, exercised once here so Plan 05's
# CODEOWNERS matches exactly):
#   - team-storefront: frontend, adservice, recommendationservice
#   - team-commerce:   cartservice, checkoutservice, paymentservice, shippingservice
#   - team-catalog:    productcatalogservice, currencyservice
#   - team-comms:      emailservice, loadgenerator
#   - team-media:      the custom Go media service
#   - team-platform:   the workflow directory (.github/**), root configuration,
#                       and the infra/gitops/docs repositories
#
# Team-per-service (12 teams, one per Online-Boutique microservice) was
# considered and rejected as Conway's-law overreach for a solo-developer
# simulation — six teams already exercises the CODEOWNERS-routing and
# team-repository-grant mechanics this project studies, without inventing
# organisational structure the estate doesn't actually have. Recorded here
# for Plan 08's study notes to pick up.

resource "github_team" "team_platform" {
  name        = "team-platform"
  description = "Owns .github/** (workflow directory), root configuration, and the infra/gitops/docs repositories. Models workflow-change protection (workflow-injection defense, D-07)."
  privacy     = "closed"
}

resource "github_team" "team_storefront" {
  name        = "team-storefront"
  description = "Owns frontend, adservice, recommendationservice."
  privacy     = "closed"
}

resource "github_team" "team_commerce" {
  name        = "team-commerce"
  description = "Owns cartservice, checkoutservice, paymentservice, shippingservice."
  privacy     = "closed"
}

resource "github_team" "team_catalog" {
  name        = "team-catalog"
  description = "Owns productcatalogservice, currencyservice."
  privacy     = "closed"
}

resource "github_team" "team_comms" {
  name        = "team-comms"
  description = "Owns emailservice, loadgenerator."
  privacy     = "closed"
}

resource "github_team" "team_media" {
  name        = "team-media"
  description = "Owns the custom Go media service (Postgres + S3 uploads + Redis sessions)."
  privacy     = "closed"
}

# --- Memberships -------------------------------------------------------
#
# A solo developer simulating a platform org is a member of every team —
# that is the honest modelling per D-07.
#
# NOTE (deviation, Rule 1 — bug prevention): developer_username (YahiaEng)
# is an organisation OWNER of AuraBit (verified live: role=admin), and the
# provider's own docs warn that org owners "may not be set as 'members' of
# a team; they may only be set as 'maintainers'" — setting role="member" for
# an owner produces a perpetual plan diff as GitHub silently reverts it to
# maintainer. All memberships below use role="maintainer" accordingly, not
# the "member" role a non-owner developer account would use.

locals {
  domain_teams = {
    team_platform   = github_team.team_platform.id
    team_storefront = github_team.team_storefront.id
    team_commerce   = github_team.team_commerce.id
    team_catalog    = github_team.team_catalog.id
    team_comms      = github_team.team_comms.id
    team_media      = github_team.team_media.id
  }
}

resource "github_team_membership" "developer" {
  for_each = local.domain_teams

  team_id  = each.value
  username = var.developer_username
  role     = "maintainer"
}
