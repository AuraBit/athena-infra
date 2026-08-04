# variables.tf — modules/core-network v0.1.0 (Plan 02-01, Task 1), extended
# by Plan 02-03 (subnets/NAT/routes) and 02-05 (S3 gateway endpoint and
# beyond).
#
# availability_zones/subnet_newbits/single_nat_gateway all carry defaults
# that make sense for dev (three us-east-1 AZs, /20 subnets, one shared NAT)
# so dev's env root does not need to override them — only stg/prod (Plan
# 02-08+) are expected to pass different values (NAT-per-AZ in particular,
# per D-22's cost-vs-HA toggle).

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

# --- Plan 02-03, Task 1: three-AZ, three-tier subnet layout ----------------

variable "availability_zones" {
  description = "AZs the subnet layout is stamped across, one public/private-app/private-data trio per AZ. Default matches dev; stg/prod pass the same list explicitly once their env roots exist (Plan 02-08+)."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "subnet_newbits" {
  description = <<-EOT
    Additional network bits carved from var.vpc_cidr for each subnet
    (cidrsubnet's "newbits" argument). Default 4 turns a /16 supernet into
    /20 subnets — the same arithmetic reproduces dev's 10.0.0.0/16, stg's
    10.1.0.0/16 and prod's 10.2.0.0/16 identically (D-21), so this is a
    single input rather than any literal CIDR ever being written by hand.
  EOT
  type        = number
  default     = 4
}

# --- Plan 02-03, Task 2: NAT egress toggle ----------------------------------

variable "single_nat_gateway" {
  description = <<-EOT
    true  -> one shared NAT gateway for every AZ's private-app subnets
             (lower fixed cost; an AZ outage removes private-app egress
             entirely, since there is no cross-AZ NAT to fall back to).
    false -> one NAT gateway per AZ (N times the fixed cost; an AZ outage
             only removes egress for that one AZ). Production uses false;
             dev's default of true takes the cost saving (D-22).
  EOT
  type        = bool
  default     = true
}

# --- Plan 02-05, Task 2: flow-logs bucket lifecycle -------------------------

variable "flow_log_transition_days" {
  description = "Days after object creation before a flow-log object transitions to STANDARD_IA (D-27). Default balances query-recency (Standard storage) against cost for the older, rarely-queried tail of the retention window."
  type        = number
  default     = 30
}

variable "flow_log_retention_days" {
  description = "Days after object creation before a flow-log object expires entirely (D-27). Must exceed flow_log_transition_days; this module does not enforce that ordering itself (the S3 lifecycle API already rejects an invalid rule), but the default values keep them coherent."
  type        = number
  default     = 365
}
