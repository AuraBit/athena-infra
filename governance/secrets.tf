# secrets.tf — governance over the estate's cross-repository CI credential
# (Plan 03-08, Task 3; CI-07/CD-04's dev handoff).
#
# WHAT IS DECLARED HERE, AND WHAT DELIBERATELY IS NOT.
#
# The `ATHENA_CI_BOT_TOKEN` Actions secret (athena-ci-bot's PAT, push scope
# on athena-gitops) is hand-provisioned per
# docs/runbooks/github-bootstrap.md's credential-handling rules and was
# adopted, not recreated, by this plan — it already existed on athena-app
# and athena-infra when Task 3 checked (the estate's existing precedent for
# pre-provisioned governance resources, cf. imports.sh).
#
# It is NOT declared as a `github_actions_secret` resource on purpose:
# that resource requires the plaintext in Terraform's variables and stores
# it retrievably in STATE — a plaintext credential copy in a file this repo
# treats as an artifact. The runbook model (value lives only in GitHub's
# secret store; provisioning is a documented human step) is the stronger
# custody discipline, so Terraform's job here is PRESENCE ASSERTION, not
# value management: the data sources below read only secret NAMES and
# timestamps, and the check blocks turn a missing/renamed secret into a
# visible plan-time warning instead of a silent workflow failure.
#
# WHY THE SECRET MATTERS (the load-bearing credential choice): a push made
# with a workflow's own default GITHUB_TOKEN does not trigger workflows in
# the target repository. media-ci.yml's gitops-handoff job pushes the dev
# image-pin commit to athena-gitops WITH THIS PAT precisely so that push
# DOES trigger athena-gitops's render workflow. Use the default token there
# and the handoff "works" — the commit lands — while the render pipeline
# silently never runs. That failure mode is why Phase 1 created the bot.

data "github_actions_secrets" "athena_app" {
  name = github_repository.athena_app.name
}

data "github_actions_secrets" "athena_infra" {
  name = github_repository.athena_infra.name
}

check "athena_app_bot_token_present" {
  assert {
    condition = contains(
      [for s in data.github_actions_secrets.athena_app.secrets : s.name],
      "ATHENA_CI_BOT_TOKEN"
    )
    error_message = "athena-app is missing the ATHENA_CI_BOT_TOKEN Actions secret — media-ci.yml's gitops-handoff job cannot push the dev image pin to athena-gitops. Provision it per docs/runbooks/github-bootstrap.md (bot PAT, push scope on athena-gitops)."
  }
}

check "athena_infra_bot_token_present" {
  assert {
    condition = contains(
      [for s in data.github_actions_secrets.athena_infra.secrets : s.name],
      "ATHENA_CI_BOT_TOKEN"
    )
    error_message = "athena-infra is missing the ATHENA_CI_BOT_TOKEN Actions secret — the Terraform workflows' sticky-comment steps depend on it. Provision it per docs/runbooks/github-bootstrap.md."
  }
}

# Added 2026-08-05 (Phase 3 security review, T-03-60 drill divergence #2):
# promote.yml's commit job runs IN athena-gitops and checks out with this
# secret — its absence there was invisible to the two checks above and
# surfaced only when the drill's first approved promotion failed
# post-approval. Same presence-assertion custody model as the others.
data "github_actions_secrets" "athena_gitops" {
  name = github_repository.athena_gitops.name
}

check "athena_gitops_bot_token_present" {
  assert {
    condition = contains(
      [for s in data.github_actions_secrets.athena_gitops.secrets : s.name],
      "ATHENA_CI_BOT_TOKEN"
    )
    error_message = "athena-gitops is missing the ATHENA_CI_BOT_TOKEN Actions secret — promote.yml's commit job cannot push the gated promotion. Provision it per docs/runbooks/github-bootstrap.md (bot PAT, push scope on athena-gitops)."
  }
}
