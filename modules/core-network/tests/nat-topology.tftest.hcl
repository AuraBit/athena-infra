# nat-topology.tftest.hcl -- mock-provider tests for the single_nat_gateway
# toggle in both directions (Plan 02-07, Task 1; D-22, D-09).
#
# See core-network.tftest.hcl's header comment for why mock_provider needs no
# credentials/network/LocalStack, and why it accepts no provider-level
# configuration of its own. Both runs below use `command = apply` rather than
# `plan` for the same reason that file's no_private_data_default_route run
# does: every assertion here compares `.id`/`.subnet_id` values, and those
# are provider-computed attributes that stay unknown under mock_provider
# until apply (empirically confirmed while authoring this suite). Applying
# is still entirely local and instant -- mock_provider fabricates every
# computed value itself, never touching LocalStack, credentials or the
# network.

# See core-network.tftest.hcl's header comment for the same override, for
# the same reason (aws_flow_log.this's log_destination ARN-shape validation
# still runs against a mocked resource, and mock_provider's fabricated `arn`
# for aws_s3_bucket.flow_logs is not ARN-shaped).
mock_provider "aws" {}

override_resource {
  target = aws_s3_bucket.flow_logs
  values = {
    arn = "arn:aws:s3:::athena-flowlogs-mock"
  }
}

variables {
  name_prefix = "athena"
  environment = "dev"
  vpc_cidr    = "10.0.0.0/16"
}

# --- Run 1: single_nat_gateway = true ---------------------------------------
#
# One shared NAT gateway, and every AZ's private-app route -- including the
# AZs that are NOT the shared gateway's own AZ -- targets that same one.
run "single_nat_gateway_true" {
  command = apply

  variables {
    single_nat_gateway = true
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1
    error_message = "single_nat_gateway = true must plan exactly one NAT gateway, got ${length(aws_nat_gateway.this)}"
  }

  assert {
    condition = alltrue([
      for az in var.availability_zones :
      aws_route.private_app_nat[az].nat_gateway_id == aws_nat_gateway.this[var.availability_zones[0]].id
    ])
    error_message = "every AZ's private-app route must target the single shared NAT gateway when single_nat_gateway is true"
  }
}

# --- Run 2: single_nat_gateway = false (NAT per AZ) -------------------------
#
# One NAT gateway per AZ, each one genuinely IN its own AZ's public subnet
# (not merely a map entry keyed by that AZ's name), and each AZ's
# private-app route targets its own AZ's gateway -- the per-zone pairing
# that is the entire point of paying the expensive topology's cost.
run "nat_per_availability_zone" {
  command = apply

  variables {
    single_nat_gateway = false
  }

  assert {
    condition     = length(aws_nat_gateway.this) == length(var.availability_zones)
    error_message = "single_nat_gateway = false must plan one NAT gateway per AZ, got ${length(aws_nat_gateway.this)} for ${length(var.availability_zones)} AZs"
  }

  # The per-zone PAIRING is the whole point of this expensive topology: each
  # NAT gateway must sit in its OWN AZ's public subnet. A route-target-by-id
  # assertion alone would be tautological here -- routes.tf computes
  # `aws_nat_gateway.this[each.value].id` directly, so a for_each map keyed
  # by 3 distinct AZ names still resolves to 3 distinct, "correct-looking"
  # ids even if every gateway's own subnet_id were wrong (e.g. all three
  # placed in the first AZ's public subnet). This assertion checks placement
  # directly instead, which is what actually catches that mutation.
  assert {
    condition = alltrue([
      for az in var.availability_zones :
      aws_nat_gateway.this[az].subnet_id == aws_subnet.this["public-${az}"].id
    ])
    error_message = "at least one NAT gateway is not planned in its own AZ's public subnet"
  }

  assert {
    condition = alltrue([
      for az in var.availability_zones :
      aws_route.private_app_nat[az].nat_gateway_id == aws_nat_gateway.this[az].id
    ])
    error_message = "each AZ's private-app route must target the NAT gateway in its own AZ, not a different AZ's gateway"
  }
}
