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
