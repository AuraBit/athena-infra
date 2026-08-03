# nat.tf — modules/core-network v0.3.0 (Plan 02-03, Task 2; CONTEXT.md D-22).
#
# Internet gateway (the public tier's only path to/from the internet) plus
# NAT egress for the private-app tier, with a single input controlling
# whether there is one shared NAT gateway or one per availability zone.

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-${var.environment}-igw"
  }
}

locals {
  # nat_azs is the list of AZs that actually get their own NAT gateway.
  #
  # single_nat_gateway = true  -> just the first AZ (one NAT total, shared
  #                                by every private-app route table).
  # single_nat_gateway = false -> every AZ (one NAT per AZ).
  #
  # This is expressed as a computed list fed into a single for_each below —
  # deliberately not two mutually exclusive `count` blocks (one for the
  # single-NAT case, one for per-AZ), which would produce resource
  # addresses that shift when the flag flips and a destructive diff on every
  # toggle. for_each keyed by AZ name means flipping the flag only adds or
  # removes the AZs whose NAT membership actually changed.
  nat_azs = var.single_nat_gateway ? [var.availability_zones[0]] : var.availability_zones

  # Cost-versus-availability, the deliberate teaching moment D-22 and this
  # phase's Specific Ideas both call out: a NAT gateway is billed per hour
  # it exists PLUS per gigabyte it processes, so one NAT per AZ multiplies
  # the fixed hourly cost by the AZ count. What that spend buys is that
  # losing one availability zone does not remove private-app egress for the
  # AZs that are still up — each AZ's private-app route table only ever
  # points at a NAT in its own AZ, so an AZ outage only takes out that AZ's
  # own NAT and route.
  #
  # Non-production environments (dev here) take the single-NAT saving and
  # accept that an AZ failure removes private-app egress entirely — there is
  # no cross-AZ NAT failover to fall back to. Production does not take that
  # trade: single_nat_gateway = false there buys the AZ-outage resilience at
  # N times the fixed cost.
  #
  # This estate spends nothing in either mode (LocalStack is free either
  # way) — the toggle exists purely so the cost/HA reasoning above is
  # demonstrable as a real Terraform input, not just asserted in a comment.
}

resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)

  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-${var.environment}-nat-eip-${substr(each.value, -1, 1)}"
  }
}

resource "aws_nat_gateway" "this" {
  for_each = toset(local.nat_azs)

  allocation_id = aws_eip.nat[each.value].id
  subnet_id     = local.subnet_ids_by_tier_and_az["public-${each.value}"]

  tags = {
    Name = "${var.name_prefix}-${var.environment}-nat-${substr(each.value, -1, 1)}"
  }

  depends_on = [aws_internet_gateway.this]
}
