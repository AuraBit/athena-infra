# outputs.tf — envs/dev/core-network (Plan 02-01, Task 1).
#
# Re-exports the module's outputs at the env-root level — this is what
# `terraform output -json` in this directory reports, and exactly what
# scripts/verify-network.sh (Task 2) reads and asserts against a real
# `ec2 describe-vpcs` call (D-23, IAC-04).

output "vpc_id" {
  description = "ID of the dev core-network VPC."
  value       = module.core_network.vpc_id
}

output "vpc_cidr_block" {
  description = "CIDR block of the dev core-network VPC."
  value       = module.core_network.vpc_cidr_block
}

# --- Plan 02-03, Task 1: subnet outputs -------------------------------------

output "public_subnet_ids" {
  description = "IDs of dev's public-tier subnets."
  value       = module.core_network.public_subnet_ids
}

output "private_app_subnet_ids" {
  description = "IDs of dev's private-app-tier subnets."
  value       = module.core_network.private_app_subnet_ids
}

output "private_data_subnet_ids" {
  description = "IDs of dev's private-data-tier subnets."
  value       = module.core_network.private_data_subnet_ids
}

output "subnet_ids_by_tier" {
  description = "Map of tier name -> list of subnet ids in that tier, for dev."
  value       = module.core_network.subnet_ids_by_tier
}
