# outputs.tf — envs/prod/data-storage (Plan 03-02, Task 2).
#
# Re-exports the module's outputs at the env-root level — this is what
# `terraform output -json` in this directory reports, and exactly what
# scripts/verify-data-storage.sh (Task 2) reads and asserts against real
# awslocal calls (D-23, IAC-04).

output "media_bucket_name" {
  description = "Name of prod's media S3 bucket."
  value       = module.data_storage.media_bucket_name
}

output "media_bucket_arn" {
  description = "ARN of prod's media S3 bucket."
  value       = module.data_storage.media_bucket_arn
}

output "media_bucket_regional_domain_name" {
  description = "Regional domain name of prod's media S3 bucket."
  value       = module.data_storage.media_bucket_regional_domain_name
}
