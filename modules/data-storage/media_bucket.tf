# media_bucket.tf — modules/data-storage v0.1.0 (Plan 03-02, Task 1;
# CONTEXT.md D-07, D-02, docs/tagging-standard.md).
#
# The seed of the Data/Storage lifecycle stack: exactly one resource set,
# the media S3 bucket Plan 03-05's uploads stream into. Phase 6 grows this
# module with RDS Postgres and ElastiCache Redis rather than inventing the
# stack from a blank directory — this file's own shape (bucket + versioning
# + public-access-block + KMS encryption, no lifecycle) is deliberately the
# smallest correct version of what modules/core-network's flow-logs.tf
# already proved out for a different bucket.
#
# Tagging: aws_s3_bucket is already in checkov/custom/athena_required_tags.py
# TRUSTED_DEFAULT_TAGS_RESOURCES (proven by the flow-logs bucket in Plan
# 02-05) — the six mandatory tags are NOT written here; they are inherited
# structurally from the provider's default_tags block (provider.tf). Only
# Name and Protection are set explicitly, matching flow-logs.tf's own
# pattern: Protection is deliberately per-resource, never a provider
# default (docs/tagging-standard.md explains why at length) — this bucket
# holds user-uploaded media, the estate's stand-in for irreplaceable user
# data, so destroying it must be a deliberate, gated act once Phase 6's OPA
# policy reads this tag.
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "media" {
  # checkov:skip=CKV2_AWS_61: media objects are user-uploaded content with
  # no defined retention window — unlike the flow-logs bucket (which
  # exists specifically to age out), there is nothing about this bucket's
  # purpose that implies an automatic transition/expiration schedule.
  # Phase 6's Data/Storage expansion may add a storage-class-transition
  # rule for infrequently-accessed media as a genuine cost optimisation,
  # but that is a future, deliberate addition — not a gap in this bucket's
  # own correctness today.
  bucket = local.media_bucket_name

  tags = {
    Name = "${var.name_prefix}-${var.environment}-media"
    # Protection (docs/tagging-standard.md): media objects are the
    # estate's stand-in for irreplaceable user data. A per-resource tag,
    # never a provider default — see that document for why Protection is
    # deliberately excluded from default_tags.
    Protection = "true"
  }
}

resource "aws_s3_bucket_versioning" "media" {
  bucket = aws_s3_bucket.media.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "media" {
  bucket = aws_s3_bucket.media.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Customer-managed KMS key, not SSE-S3 (AES256) — found live (Plan 03-02,
# Task 1): Checkov's CKV_AWS_145 ("Ensure that S3 buckets are encrypted
# with KMS by default") hard-fails an AES256-only configuration under this
# repo's blocking gate (D-24), the same finding modules/core-network's
# flow-logs.tf already resolved this same way. Unlike flow-logs.tf's key
# policy (which must explicitly grant delivery.logs.amazonaws.com access,
# since that AWS service — not this account — writes the objects), this
# key's policy grants only account-root full access: every principal that
# reads/writes media objects in this project acts under the same simulated
# account's own credentials (D-16 — this estate's whole security model is
# account-level via access keys, not per-principal IAM roles within an
# account), so no cross-principal grant is needed at this stack's current
# size. A future plan introducing a distinct media-service IAM role would
# extend this key's policy the same way flow-logs.tf's does today, not
# replace it.
resource "aws_kms_key" "media" {
  description             = "${var.name_prefix}-${var.environment} media bucket encryption key"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAccountRootFullAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
    ]
  })

  tags = {
    Name = "${var.name_prefix}-${var.environment}-media-key"
  }
}

resource "aws_kms_alias" "media" {
  name          = "alias/${var.name_prefix}-${var.environment}-media"
  target_key_id = aws_kms_key.media.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  bucket = aws_s3_bucket.media.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.media.arn
    }
    bucket_key_enabled = true
  }
}
