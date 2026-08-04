# terraform.tfvars — envs/dev/core-network (Plan 02-01, Task 1; CONTEXT.md
# D-21 non-overlapping supernet plan: dev 10.0.0.0/16, stg 10.1.0.0/16,
# prod 10.2.0.0/16).
#
# Plan 02-03 adds availability_zones/subnet_newbits/single_nat_gateway to
# modules/core-network, all defaulted for dev (three us-east-1 AZs, /20
# subnets, one shared NAT) — this file intentionally does not gain new
# entries for them; see envs/dev/core-network/main.tf's module block for
# why. stg/prod will need explicit values here once their own env roots
# exist (Plan 02-08+).
name_prefix = "athena"
environment = "stg"
vpc_cidr    = "10.1.0.0/16"

# Plan 02-08, Task 2: stg turns the NAT toggle OFF-of-single (one NAT
# gateway per AZ, not one shared) deliberately — stg exists to rehearse
# production, and a staging environment whose network topology differs
# from production's is a staging environment that cannot rehearse a zone
# failure. The cost saving that justifies dev's single-NAT default does
# not justify making stg unrepresentative of what prod actually runs.
single_nat_gateway = false

# Plan 02-05, Task 2: dev takes the module's own defaults explicitly here
# (30/365) rather than leaving them implicit — see variables.tf's header.
flow_log_transition_days = 30
flow_log_retention_days  = 365
