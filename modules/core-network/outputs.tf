# outputs.tf — modules/core-network v0.1.0 (Plan 02-01, Task 1).
#
# vpc_id is the identifier scripts/verify-network.sh (Task 2) asserts against
# a real `ec2 describe-vpcs` call — the output-driven verification contract
# (D-23) that every later addition to this module's output set must keep
# satisfying.
#
# Comment-only touch (Plan 02-04, Task 3): this modules/core-network-only
# change is the live-verification PR for the "modules-only PR plans zero
# environments" acceptance criterion -- dorny/paths-filter should report
# modules=true, dev/stg/prod=false, changed_envs=[], the plan matrix should
# fan to zero legs (skipped, not failed), and the gate job should report
# that skip as an explicitly-reasoned, intentional pass.

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

# --- Plan 02-03, Task 2: internet gateway, NAT and route table outputs -----

output "internet_gateway_id" {
  description = "ID of the internet gateway attached to this VPC."
  value       = aws_internet_gateway.this.id
}

output "nat_gateway_ids" {
  description = "IDs of every NAT gateway this module created — one entry when single_nat_gateway is true, one per AZ when false."
  value       = [for az, nat in aws_nat_gateway.this : nat.id]
}

output "public_route_table_id" {
  description = "ID of the single shared public route table."
  value       = aws_route_table.public.id
}

output "private_app_route_table_ids" {
  description = "IDs of the private-app route tables, one per AZ."
  value       = [for az, rt in aws_route_table.private_app : rt.id]
}

output "private_data_route_table_ids" {
  description = "IDs of the private-data route tables, one per AZ. None of these carry a 0.0.0.0/0 route — that absence is the tier's whole purpose."
  value       = [for az, rt in aws_route_table.private_data : rt.id]
}

# --- Plan 02-03, Task 3: S3 gateway VPC endpoint ----------------------------

output "s3_vpc_endpoint_id" {
  description = "ID of the S3 gateway VPC endpoint attached to every private route table (private-app and private-data)."
  value       = aws_vpc_endpoint.s3.id
}

output "s3_vpc_endpoint_prefix_list_id" {
  description = "AWS-managed prefix list id the S3 gateway endpoint injects a route for into its attached route tables."
  value       = aws_vpc_endpoint.s3.prefix_list_id
}

# --- Plan 02-05, Task 2: flow-logs bucket + flow log outputs ---------------

output "flow_logs_bucket_name" {
  description = "Name of the per-environment VPC flow-logs S3 bucket (athena-flowlogs-<environment>)."
  value       = aws_s3_bucket.flow_logs.bucket
}

output "flow_logs_bucket_arn" {
  description = "ARN of the per-environment VPC flow-logs S3 bucket."
  value       = aws_s3_bucket.flow_logs.arn
}

output "flow_log_id" {
  description = "ID of the VPC flow log delivering to flow_logs_bucket_name."
  value       = aws_flow_log.this.id
}
