# variables.tf — envs/dev/core-network (Plan 02-01, Task 1).
#
# Mirrors modules/core-network's own variables; this env root's tfvars file
# supplies the actual dev values.
#
# Comment-only touch (Plan 02-04, Task 3): this file's own change is the
# live-verification PR that exercises terraform-core-network.yml end to
# end for the first time now that the workflow exists on main -- a
# comment-only edit produces a clean "No changes" plan/apply, proving the
# pipeline's shell logic and gating without risking any real drift against
# the already-applied dev stack.

variable "name_prefix" {
  description = "Short project/estate prefix used in resource Name tags."
  type        = string
}

variable "environment" {
  description = "Environment this stack applies to."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the dev VPC (D-21: 10.0.0.0/16)."
  type        = string
}

# single_nat_gateway is declared (and wired through in main.tf) at this env
# root — unlike availability_zones/subnet_newbits, which stay pure module
# defaults — specifically so the toggle is a real, settable input here, not
# just inside the module: D-22's whole point is that the cost-vs-HA
# reasoning is demonstrable via `terraform plan -var single_nat_gateway=false`
# against this root, not merely asserted in a comment.
variable "single_nat_gateway" {
  description = "true = one shared NAT gateway (dev's default); false = one NAT gateway per AZ (prod)."
  type        = bool
  default     = true
}
