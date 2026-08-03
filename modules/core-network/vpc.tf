# vpc.tf — modules/core-network v0.1.0 (Plan 02-01, Task 1; CONTEXT.md D-22
# first slice, D-25 in-house).
#
# This is the first AWS-provider resource in the estate. Deliberately thin:
# one aws_vpc and nothing else. The full enterprise topology D-22 describes
# (three AZs, three subnet tiers, IGW, NAT, route tables, S3 gateway
# endpoint, flow logs, baseline SGs) is built by Plan 02-03 and 02-05 as
# expansions of this same module — proving the tracer path (module -> tag ->
# env root -> apply -> awslocal verify) end to end here, before any of that
# topology exists, is the whole point of this plan.
#
# terraform-aws-modules/vpc is used as a design reference only (D-25); this
# module is authored in-house so the interview depth is in VPC internals,
# not in consuming someone else's abstraction.

resource "aws_vpc" "this" {
  # checkov:skip=CKV2_AWS_11: Flow logs land in a per-env S3 bucket
  # (athena-flowlogs-<env>) that is Plan 02-05's deliverable (D-27) — this
  # module does not yet own the aws_flow_log resource that would satisfy
  # this check. Tracked here, not silently ignored; Plan 02-05 removes this
  # suppression when it adds that resource.
  # checkov:skip=CKV2_AWS_12: Default-SG lockdown (stripping the VPC's
  # default security group down to zero permissive rules) is Plan 02-05's
  # baseline-SG deliverable (D-28) — this module does not yet own that
  # resource either. Same tracked-not-ignored reasoning as CKV2_AWS_11
  # above; Plan 02-05 removes this suppression too.
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-${var.environment}-core-network-vpc"
  }
}
