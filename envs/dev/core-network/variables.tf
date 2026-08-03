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
