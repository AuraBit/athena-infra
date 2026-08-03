# variables.tf — modules/core-network v0.1.0 (Plan 02-01, Task 1).
#
# Deliberately minimal for this slice: only the inputs the single aws_vpc
# resource in vpc.tf needs. Subnets/NAT/routes/endpoints/flow-logs/SGs are
# Plan 02-03 and 02-05 expansions of this same module and will add their own
# variables alongside these, not replace them.

variable "name_prefix" {
  description = "Short project/estate prefix used in resource Name tags (e.g. \"athena\")."
  type        = string
}

variable "environment" {
  description = "Environment this VPC belongs to (dev, stg, or prod) — also carried as the Environment tag."
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prod"], var.environment)
    error_message = "environment must be one of: dev, stg, prod."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC (D-21 non-overlapping per-env supernet plan: dev 10.0.0.0/16, stg 10.1.0.0/16, prod 10.2.0.0/16)."
  type        = string
}
