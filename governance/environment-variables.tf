# environment-variables.tf — per-environment Actions VARIABLES carrying
# athena-infra's simulated AWS configuration (D-13, Plan 02-06 Task 2).
#
# VARIABLES, not secrets. None of the five values below is secret: they are
# either LocalStack's account-namespacing literals (D-16 — the access key
# alone determines which simulated account a request lands in, not any real
# authorisation) or plain, non-sensitive configuration (a region, a
# localhost URL, a bucket name). Declaring them as `github_actions_secret`
# would teach the wrong lesson about what a secret actually is — a value an
# attacker gains something real by reading. Contrast this with
# `LOCALSTACK_AUTH_TOKEN` (org.tf), which stays an organisation-level
# Actions SECRET, because it genuinely is one: a real credential against a
# real (if free-tier) external service.
#
# Scoped PER ENVIRONMENT, not per repository, because the scoping IS the
# control this file models. GitHub only injects the variables of the
# Environment a job actually declares (`environment: ${{ matrix.env }}` in
# terraform-core-network.yml's `apply` job) — so a `plan (dev)` job, which
# declares no Environment at all, cannot read `prod`'s configuration, and
# an `apply (dev)` job cannot read `stg`'s or `prod`'s either. Today that
# separates six sets of simulated-account literals. The day this estate
# points at real AWS via OIDC, the exact same seam separates a read-only
# plan role's identity from a read-write apply role's — nothing in the
# workflow or in envs/*/core-network's Terraform roots has to change, only
# the values these variables carry. That is the whole justification for
# provisioning six Environments' worth of near-identical variables instead
# of one repository-level set.

locals {
  # One entry per BASE environment (dev/stg/prod) — the simulated 12-digit
  # account id each namespaces into (D-16). Everything else this file
  # computes derives from this single map, including the dev-plan/stg-plan/
  # prod-plan entries below, so an environment and its plan-variant
  # counterpart cannot structurally disagree.
  infra_env_account_ids = {
    dev  = "111111111111"
    stg  = "222222222222"
    prod = "333333333333"
  }

  # The five variables every Environment (gated or plan-variant) carries,
  # keyed by the BASE environment name — merged into the gated name and the
  # "<env>-plan" name below from this one map entry, never typed twice.
  infra_env_variable_values = {
    for env, account_id in local.infra_env_account_ids : env => {
      AWS_ACCESS_KEY_ID     = account_id
      AWS_SECRET_ACCESS_KEY = account_id
      AWS_DEFAULT_REGION    = "us-east-1" # matches envs/*/core-network/backend.tf and provider.tf
      AWS_ENDPOINT_URL      = "http://localhost:4566"
      TF_STATE_BUCKET       = "athena-tfstate-${env}"
    }
  }

  # Merge the gated Environment's variable set with its ungated plan-variant
  # counterpart's — both read from infra_env_variable_values[env] above, so
  # "dev-plan" cannot silently drift from "dev".
  infra_env_variables_by_environment = merge(
    local.infra_env_variable_values,
    { for env, vars in local.infra_env_variable_values : "${env}-plan" => vars }
  )

  # Flatten to one entry per (environment, variable name) pair — the shape
  # a single for_each resource block actually iterates over.
  infra_env_variables_flat = merge([
    for env, vars in local.infra_env_variables_by_environment : {
      for variable_name, variable_value in vars :
      "${env}.${variable_name}" => {
        environment   = env
        variable_name = variable_name
        value         = variable_value
      }
    }
  ]...)
}

resource "github_actions_environment_variable" "this" {
  for_each = local.infra_env_variables_flat

  repository    = github_repository.athena_infra.name
  environment   = each.value.environment
  variable_name = each.value.variable_name
  value         = each.value.value

  depends_on = [
    github_repository_environment.infra_dev,
    github_repository_environment.infra_stg,
    github_repository_environment.infra_prod,
    github_repository_environment.infra_dev_plan,
    github_repository_environment.infra_stg_plan,
    github_repository_environment.infra_prod_plan,
  ]
}
