# outputs.tf — modules/core-network v0.1.0 (Plan 02-01, Task 1).
#
# vpc_id is the identifier scripts/verify-network.sh (Task 2) asserts against
# a real `ec2 describe-vpcs` call — the output-driven verification contract
# (D-23) that every later addition to this module's output set must keep
# satisfying.

output "vpc_id" {
  description = "ID of the VPC created by this module."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC created by this module."
  value       = aws_vpc.this.cidr_block
}

# --- Plan 02-03, Task 1: subnet outputs -------------------------------------

output "public_subnet_ids" {
  description = "IDs of the public-tier subnets, one per availability zone."
  value       = local.subnet_ids_by_tier["public"]
}

output "private_app_subnet_ids" {
  description = "IDs of the private-app-tier subnets, one per availability zone."
  value       = local.subnet_ids_by_tier["private-app"]
}

output "private_data_subnet_ids" {
  description = "IDs of the private-data-tier subnets, one per availability zone. This tier deliberately never gets a default route to the internet (Plan 02-03, Task 2)."
  value       = local.subnet_ids_by_tier["private-data"]
}

output "subnet_ids_by_tier" {
  description = "Map of tier name -> list of subnet ids in that tier. scripts/verify-network.sh reads the three per-tier outputs above rather than this map directly, but it is useful for quick inspection (`terraform output subnet_ids_by_tier`)."
  value       = local.subnet_ids_by_tier
}
