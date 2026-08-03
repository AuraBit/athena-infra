# subnets.tf — modules/core-network v0.2.0 (Plan 02-03, Task 1; CONTEXT.md
# D-21, D-22).
#
# Nine subnets: three availability zones crossed with three tiers (public,
# private-app, private-data). Every CIDR is derived with cidrsubnet() over
# var.vpc_cidr — never written out as a literal — so the exact same
# arithmetic reproduces dev's 10.0.0.0/16, stg's 10.1.0.0/16 and prod's
# 10.2.0.0/16 allocations unchanged (D-21's whole point).

locals {
  # Tier ordering is deliberately fixed and public-first: it is also the
  # ordering the cidr_index below walks (tier-major, then AZ), so this list
  # is the single source of truth for "which tier gets which CIDR block".
  subnet_tiers = ["public", "private-app", "private-data"]

  # subnet_specs is keyed "<tier>-<az>" (a stable string), not a numeric
  # position — this is what lets aws_subnet.this below use for_each instead
  # of count. count indexes resources by position in a list, so adding or
  # removing a single AZ from var.availability_zones would renumber every
  # subnet after it and destroy/recreate subnets that never actually
  # changed. Keying by "<tier>-<az>" means only the AZ that is genuinely
  # added or removed is affected; every other subnet's address is untouched.
  subnet_specs = {
    for pair in flatten([
      for tier_index, tier in local.subnet_tiers : [
        for az_index, az in var.availability_zones : {
          key  = "${tier}-${az}"
          tier = tier
          az   = az
          # Deterministic index ordering: tier-major, then AZ. Tier 0's AZs
          # take cidrsubnet indices 0..n-1, tier 1's take n..2n-1, and so
          # on — reproducible across envs sharing this module.
          cidr_index = (tier_index * length(var.availability_zones)) + az_index
        }
      ]
    ]) : pair.key => pair
  }
}

resource "aws_subnet" "this" {
  for_each = local.subnet_specs

  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, var.subnet_newbits, each.value.cidr_index)
  availability_zone       = each.value.az
  map_public_ip_on_launch = each.value.tier == "public"

  tags = {
    # az-suffix is the trailing AZ letter (e.g. "a" from "us-east-1a") —
    # substr's negative offset counts from the end of the string.
    Name = "${var.name_prefix}-${var.environment}-${each.value.tier}-${substr(each.value.az, -1, 1)}"
    Tier = each.value.tier
  }
}

locals {
  # Grouped by tier for the three per-tier outputs and subnet_ids_by_tier —
  # computed once here so outputs.tf, routes.tf and nat.tf (Plan 02-03, Task
  # 2) can all consume the same grouping without recomputing it.
  subnet_ids_by_tier = {
    for tier in local.subnet_tiers : tier => [
      for key, subnet in aws_subnet.this : subnet.id if subnet.tags["Tier"] == tier
    ]
  }

  subnet_ids_by_tier_and_az = {
    for key, subnet in aws_subnet.this : key => subnet.id
  }
}
