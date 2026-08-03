# variables.tf — envs/dev/core-network (Plan 02-01, Task 1).
#
# Mirrors modules/core-network's own variables; this env root's tfvars file
# supplies the actual dev values.

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
