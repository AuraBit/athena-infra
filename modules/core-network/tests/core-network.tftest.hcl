# core-network.tftest.hcl -- mock-provider unit tests for modules/core-network's
# structural invariants (Plan 02-07, Task 1; D-04, D-09).
#
# mock_provider "aws" replaces the real AWS provider so every run below plans
# entirely against synthetic (mocked) resource responses -- no credentials, no
# network, no LocalStack. Native `terraform test` has supported provider
# mocking since 1.7; this repo pins 1.15.8 (ansible/roles/github-runner/
# defaults/main.yml, TF_VERSION in terraform-core-network.yml), so no version
# caveat applies. `terraform init -backend=false` still installs the real
# hashicorp/aws provider PLUGIN once (its schema is what the mock validates
# configuration against and what generates default computed values from) --
# that install is the only thing that ever touches the network, and only
# during `init`, never during `terraform test` itself.
#
# Empirically verified while authoring this suite (recorded here because it
# shapes every run below): `mock_provider` accepts no provider-level
# configuration at all -- no `region`, no `default_tags` block -- both were
# tried and rejected with "Unsupported argument"/"Unsupported block type".
# default_tags merging into `tags_all` is real hashicorp/aws provider SDK
# logic, not something Terraform core's test-file mocking reproduces, so no
# run here can observe the six estate-mandatory tags (Project, Environment,
# Stack, ManagedBy, Owner, CostCenter) the way envs/*/core-network/
# provider.tf actually injects them. Run 3 below tests the invariant that IS
# provable under mock instead: that the module's own resource-level `tags`
# never blanks/overrides one of those six keys.

mock_provider "aws" {}

# aws_flow_log.this's log_destination (flow-logs.tf) is a real hashicorp/aws
# provider-side ARN-shape validator, which still runs against a mocked
# resource's config -- mock_provider's default fabricated `arn` for
# aws_s3_bucket.flow_logs is a short random string, not ARN-shaped, so any
# `command = apply` run fails that validation before it ever reaches this
# suite's own assertions (empirically confirmed while authoring this suite).
# Overriding just the one attribute the validator inspects, file-wide so
# every apply-command run in this file gets it, sidesteps that without
# touching any of this file's own assertions.
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

# --- Run 1: subnet count + CIDR arithmetic ----------------------------------
#
# Nine subnets (3 tiers x 3 AZs). Each expected CIDR is recomputed with the
# exact same cidrsubnet() call subnets.tf's aws_subnet.this makes -- tier-
# major, then AZ (subnets.tf's own cidr_index local, restated here
# independently rather than referenced, since test files cannot read a
# module's locals). Asserting against this recomputed arithmetic, not a
# hardcoded CIDR list, is what makes this catch a real mistake in the
# module's own cidrsubnet() call rather than merely echoing whatever that
# call currently produces.
run "subnet_count_and_cidr_arithmetic" {
  command = plan

  assert {
    condition     = length(aws_subnet.this) == 9
    error_message = "expected exactly 9 subnets (3 tiers x 3 AZs), got ${length(aws_subnet.this)}"
  }

  assert {
    condition = alltrue(flatten([
      for tier_index, tier in ["public", "private-app", "private-data"] : [
        for az_index, az in var.availability_zones :
        aws_subnet.this["${tier}-${az}"].cidr_block == cidrsubnet(
          var.vpc_cidr,
          var.subnet_newbits,
          (tier_index * length(var.availability_zones)) + az_index,
        )
      ]
    ]))
    error_message = "at least one planned subnet's cidr_block does not match cidrsubnet(var.vpc_cidr, var.subnet_newbits, <tier-major index>) for its own tier/AZ"
  }
}

# --- Run 2: private-data tier gets no default route -------------------------
#
# routes.tf deliberately declares no aws_route resource for private-data --
# that absence IS the tier's whole purpose. `terraform test` cannot reference
# a resource address that does not exist in the module's .tf source (a
# parse-time "reference to undeclared resource" error -- proven empirically
# while authoring this suite; `try()` does not help, since that is a static
# reference-graph error, not a runtime one), so this assertion instead proves
# the invariant the way it is actually implemented: neither route resource
# this module DOES declare (aws_route.public_internet, aws_route.
# private_app_nat) ever targets a private-data route table's id. The
# deliberate mutation this suite is proven against (recorded in this task's
# commit message) redirects one AZ's private_app_nat route at its own
# private-data route table instead of its private-app route table -- exactly
# the shape of mistake an off-by-one branch or a copy-paste would produce,
# and exactly what this assertion catches.
#
# command = apply, not plan: `id` is a provider-computed attribute, and under
# mock_provider a computed attribute stays unknown until apply (empirically
# confirmed while authoring this suite -- comparing two resources' `.id`
# values under `command = plan` fails with "Unknown condition value" even
# though both resources are genuinely being created). Applying is still
# entirely local and instant: mock_provider fabricates every computed value
# itself, so this never touches LocalStack, credentials or the network any
# more than the plan-only runs above do.
run "no_private_data_default_route" {
  command = apply

  assert {
    condition = length(setintersection(
      toset([for az in var.availability_zones : aws_route_table.private_data[az].id]),
      toset(concat(
        [aws_route.public_internet.route_table_id],
        [for az in var.availability_zones : aws_route.private_app_nat[az].route_table_id],
      )),
    )) == 0
    error_message = "one or more private-data route tables share an id with an existing aws_route resource's route_table_id -- that tier must never receive a default route"
  }
}

# --- Run 3: no taggable resource's own config blanks a mandatory tag -------
#
# checkov/custom/athena_required_tags.py (CKV_ATHENA_1) trusts default_tags
# to reach every resource type in its TRUSTED_DEFAULT_TAGS_RESOURCES list,
# and only fails a resource of one of those types if its OWN tags block
# explicitly blanks one of the six mandatory keys (an explicit value always
# wins over the provider default on key collision). As this file's header
# comment records, mock_provider cannot simulate default_tags merging at
# all, so tags_all is never knowable here. This run instead asserts the
# thing Checkov's check actually protects, in agreement with rather than
# duplicating it: none of this module's own taggable resources set any of
# the six mandatory keys directly in their own config-level tags map, for
# every resource instance the module plans (including every AZ/tier
# for_each expansion) -- so nothing in this module could ever blank a
# default_tags-provided key even before Checkov gets a chance to check it.
run "tagging_contract_matches_checkov" {
  command = plan

  assert {
    condition = alltrue([
      for tags in concat(
        [
          aws_vpc.this.tags,
          aws_internet_gateway.this.tags,
          aws_route_table.public.tags,
          aws_vpc_endpoint.s3.tags,
          aws_s3_bucket.flow_logs.tags,
          aws_flow_log.this.tags,
          aws_default_security_group.this.tags,
          aws_security_group.allow_internal_vpc.tags,
          aws_security_group.vpc_endpoints.tags,
        ],
        [for key, subnet in aws_subnet.this : subnet.tags],
        [for az, nat in aws_nat_gateway.this : nat.tags],
        [for az, eip in aws_eip.nat : eip.tags],
        [for az, rt in aws_route_table.private_app : rt.tags],
        [for az, rt in aws_route_table.private_data : rt.tags],
      ) :
      length(setintersection(
        toset(keys(coalesce(tags, {}))),
        toset(["Project", "Environment", "Stack", "ManagedBy", "Owner", "CostCenter"]),
      )) == 0
    ])
    error_message = "a taggable resource's own tags map sets one of the six default_tags-provided mandatory keys directly, which would blank/override the provider default on that resource"
  }
}

# --- Run 4: a second, differently-shaped environment ------------------------
#
# Same arithmetic assertion as Run 1, but with stg's shape (a different /16
# supernet, a different environment name) -- proving the module is genuinely
# parameterised rather than dev-shaped with variables bolted on. "No two
# overlap" is checked directly against the 9 PLANNED cidr_block values
# (distinct() over the actual strings, not the formula re-evaluated a second
# time), so it independently proves the module never produces the same block
# twice for one environment (an index collision), on top of Run 1's proof
# that each individual value matches the formula.
run "second_environment_shape_no_overlap" {
  command = plan

  variables {
    environment = "stg"
    vpc_cidr    = "10.1.0.0/16"
  }

  assert {
    condition     = length(aws_subnet.this) == 9
    error_message = "expected exactly 9 subnets for the stg-shaped environment, got ${length(aws_subnet.this)}"
  }

  assert {
    condition = alltrue(flatten([
      for tier_index, tier in ["public", "private-app", "private-data"] : [
        for az_index, az in var.availability_zones :
        aws_subnet.this["${tier}-${az}"].cidr_block == cidrsubnet(
          var.vpc_cidr,
          var.subnet_newbits,
          (tier_index * length(var.availability_zones)) + az_index,
        )
      ]
    ]))
    error_message = "the stg-shaped environment's subnet CIDRs did not shift to the new supernet as cidrsubnet(var.vpc_cidr, var.subnet_newbits, <index>) predicts"
  }

  assert {
    condition     = length(distinct([for key, subnet in aws_subnet.this : subnet.cidr_block])) == 9
    error_message = "two or more planned subnets in the stg-shaped environment share the same cidr_block"
  }
}
