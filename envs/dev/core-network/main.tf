# main.tf — envs/dev/core-network (Plan 02-01, Task 1; CONTEXT.md D-04,
# D-29, D-30).
#
# Small, explicit env root: backend + provider + one pinned module call +
# tfvars (~30 lines total across the files in this directory, per D-30).
#
# The module source is a git-tag ref against this SAME repo, never a
# relative path (D-04) — relative-path module sources are rejected because
# they silently break the promotion audit trail: a relative source always
# resolves to whatever is on disk at apply time, with no record of which
# module version actually applied. An exact tag pin makes "what applied to
# dev on 2026-08-03" an answerable, auditable question.
module "core_network" {
  source = "git::https://github.com/AuraBit/athena-infra.git//modules/core-network?ref=modules/core-network/v0.6.0"

  name_prefix        = var.name_prefix
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  single_nat_gateway = var.single_nat_gateway

  flow_log_transition_days = var.flow_log_transition_days
  flow_log_retention_days  = var.flow_log_retention_days

  # availability_zones/subnet_newbits deliberately not overridden here: the
  # module's own defaults (three us-east-1 AZs, /20 subnets) already match
  # dev exactly (D-21). single_nat_gateway IS wired through explicitly (see
  # variables.tf) so the toggle is a real, plannable input at this root —
  # `terraform plan -var single_nat_gateway=false` is how D-22's cost-vs-HA
  # trade-off gets demonstrated, not just asserted in a comment. Prod's env
  # root (Plan 02-08+) sets its own tfvars value to false.
}
