# outputs.tf — modules/data-storage v0.1.0 (Plan 03-02, Task 1).
#
# The media service (Plan 03-05) and scripts/verify-data-storage.sh both
# key on the bucket name — it must be an output, not a convention a reader
# reconstructs from var.environment, mirroring modules/core-network's own
# output-driven verification contract (D-23).

output "media_bucket_name" {
  description = "Name of the per-environment media S3 bucket (athena-media-<environment>)."
  value       = aws_s3_bucket.media.bucket
}

output "media_bucket_arn" {
  description = "ARN of the per-environment media S3 bucket."
  value       = aws_s3_bucket.media.arn
}

output "media_bucket_regional_domain_name" {
  description = "Regional domain name of the media S3 bucket — the media service's upload endpoint (Plan 03-05)."
  value       = aws_s3_bucket.media.bucket_regional_domain_name
}
