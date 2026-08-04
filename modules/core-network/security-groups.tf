# security-groups.tf — modules/core-network v0.6.0 (Plan 02-05, Task 3;
# CONTEXT.md D-28).
#
# Two distinct concerns: taking over the VPC's un-deletable default security
# group (stripping it to zero rules) and declaring the two baseline shared
# security groups this stack owns. Workload-specific security groups arrive
# with Phase 6's compute stack — adding them here would make this
# Core/Network stack a dumping ground for concerns that belong to whichever
# stack actually owns the workload.

# --- Default security group takeover ----------------------------------------
#
# AWS creates a default security group with every VPC. Its stock rules allow
# all traffic between anything attached to it and all outbound traffic, and
# it cannot be deleted — only adopted and edited. `aws_default_security_group`
# is Terraform's mechanism for adopting it: declaring zero ingress and zero
# egress rules here strips every one of those permissive stock rules.
#
# Why adopt it instead of just ignoring it and relying on workloads always
# specifying their own security group: the default security group is
# EXACTLY the group an instance lands in when somebody forgets to specify
# one. Leaving it permissive means the least-careful path through this
# estate (the one where a future engineer omits `vpc_security_group_ids`)
# is also the least-secure path — silently wide open, not merely
# unconfigured. Adopting and stripping it means that same mistake instead
# produces a workload with NO network access at all, which is loud and
# immediately visible, not quiet and dangerous.
#
# This satisfies Checkov's CKV2_AWS_12 ("Ensure the default security group
# of every VPC restricts all traffic") — the suppression this check
# previously carried on aws_vpc.this (vpc.tf) is removed by this same
# commit, since the check's actual requirement is now genuinely met.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  # No ingress {} / egress {} blocks at all -- an empty rule set is what
  # strips every stock permissive rule. Declaring an explicit empty block
  # is unnecessary; omitting the blocks entirely is the idiomatic way to
  # express "this security group permits nothing."

  tags = {
    Name = "${var.name_prefix}-${var.environment}-default-sg-locked-down"
  }
}

# --- Baseline shared security groups -----------------------------------------
#
# Only these two. Both carry a description naming what attaches to them,
# because a security group's description is the only documentation that
# travels with the resource itself (visible in any console/describe call,
# unlike a comment in this file).

# allow-internal-vpc: the group a workload attaches to when it needs to talk
# to peers inside the VPC and nothing else -- ingress restricted to the
# VPC's own CIDR block (not 0.0.0.0/0), egress unrestricted (workloads still
# need to reach NAT-routed internet destinations, S3 via the gateway
# endpoint, and so on).
resource "aws_security_group" "allow_internal_vpc" {
  # checkov:skip=CKV_AWS_382: Unrestricted egress is this group's stated
  # design (D-28, this file's own header comment above) -- a workload
  # attached to allow-internal-vpc still needs to reach NAT-routed internet
  # destinations and the S3 gateway endpoint, and scoping egress down would
  # defeat the group's purpose. This is a deliberate baseline-group design
  # choice, not a gap a future plan closes; workload-specific groups
  # arriving with Phase 6's compute stack are expected to scope their own
  # egress far more tightly than this shared baseline group ever will.
  # checkov:skip=CKV2_AWS_5: This baseline group is declared ahead of
  # having anything to attach it to, by design (D-28) -- it exists now so
  # Phase 6's compute stack can consume its id via this module's
  # baseline_security_group_ids remote-state output instead of each
  # workload-owning stack defining an equivalent group of its own. It will
  # show as genuinely attached the moment Phase 6 attaches a real
  # ENI/instance to it; until then, "unattached" is the expected state of a
  # baseline group published for future consumption, not an oversight.
  name        = "${var.name_prefix}-${var.environment}-allow-internal-vpc"
  description = "Baseline: ingress from this VPC own CIDR only, for workloads that only ever need to reach peers inside this VPC."
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "All traffic from within this VPC own CIDR block"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Unrestricted egress: workloads on this group still need NAT-routed internet and the S3 gateway endpoint"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-${var.environment}-allow-internal-vpc"
  }
}

# vpc-endpoints: ingress on 443 from the VPC CIDR, for interface endpoints.
# This stack's only endpoint today (endpoints.tf, Plan 02-03) is the S3
# GATEWAY endpoint, which attaches to route tables and takes no security
# group at all -- gateway endpoints route by injecting a prefix-list route,
# they have no ENI and nothing to attach a security group to. This group
# exists now, ahead of having anything to attach it to, because Phase 6's
# Data/Storage stack adds INTERFACE endpoints (which do have ENIs and do
# take a security group) -- declaring this baseline group here means Phase
# 6 consumes it through this module's remote-state outputs instead of
# defining a second, slightly-different one of its own.
resource "aws_security_group" "vpc_endpoints" {
  # checkov:skip=CKV_AWS_382: Same reasoning as allow-internal-vpc above --
  # an interface endpoint's ENI still needs to answer back to whatever
  # called it, and this is a shared baseline group's deliberate design
  # (D-28), not a gap.
  # checkov:skip=CKV2_AWS_5: Same reasoning as allow-internal-vpc above --
  # declared ahead of Phase 6's interface endpoints attaching to it, by
  # design (D-28). This stack's own S3 endpoint is a gateway endpoint and
  # structurally cannot attach a security group at all.
  name        = "${var.name_prefix}-${var.environment}-vpc-endpoints"
  description = "Baseline: ingress on 443 from this VPC own CIDR, for interface VPC endpoints Phase 6 Data/Storage stack adds (this stack own S3 endpoint is a gateway endpoint and takes no security group)."
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from within this VPC own CIDR block, for interface endpoint ENIs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Unrestricted egress: an interface endpoint own ENI still needs to answer back to whatever called it"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-${var.environment}-vpc-endpoints"
  }
}
