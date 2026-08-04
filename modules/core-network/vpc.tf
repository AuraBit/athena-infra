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
  # CKV2_AWS_11's prior suppression is removed as of Plan 02-05, Task 2:
  # flow-logs.tf now owns a real aws_flow_log resource on this VPC,
  # delivering to the per-env athena-flowlogs-<env> bucket (D-27) — the
  # check's own requirement is genuinely satisfied, not suppressed.
  # CKV2_AWS_12's prior suppression is removed as of Plan 02-05, Task 3:
  # security-groups.tf now owns a real aws_default_security_group resource
  # stripping this VPC's default security group to zero ingress/egress
  # rules (D-28) — the check's own requirement is genuinely satisfied, not
  # suppressed. Both of vpc.tf's original tracked-not-ignored suppressions
  # are now gone; this module has no remaining Checkov suppression.
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-${var.environment}-core-network-vpc"
  }
}
