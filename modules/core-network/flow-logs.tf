# flow-logs.tf — modules/core-network v0.5.0 (Plan 02-05, Task 2; CONTEXT.md
# D-27, D-26).
#
# Per-environment S3 bucket for VPC flow logs, plus the flow log itself.
# This is the resource docs/tagging-standard.md's Protection-tag list names
# by example: destroying this bucket destroys audit evidence, so it is
# tagged Protection and Phase 6's OPA gate treats a delete/replace plan
# against it as something a human must review first.

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "flow_logs" {
  bucket = "athena-flowlogs-${var.environment}"

  tags = {
    Name = "${var.name_prefix}-${var.environment}-flow-logs"
    # Protection (docs/tagging-standard.md): destroying this bucket
    # destroys the VPC's audit trail. This is a per-resource tag, never a
    # provider default — see that document for why.
    Protection = "true"
  }
}

resource "aws_s3_bucket_versioning" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Customer-managed KMS key rather than SSE-S3 (AES256): the audit-evidence
# purpose this bucket exists for is exactly the case where "who can decrypt
# this data" should be a key policy this estate controls explicitly, not
# AWS's own S3-managed key with no separate access boundary. Key rotation
# is enabled so the underlying key material itself ages out on a schedule,
# independent of anything this module's own applies ever touch.
resource "aws_kms_key" "flow_logs" {
  description             = "${var.name_prefix}-${var.environment} VPC flow-logs bucket encryption key"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  # A CMK's default key policy only grants the account root full access --
  # it does NOT implicitly grant any AWS service permission to use it, the
  # way SSE-S3's AWS-managed key does. VPC Flow Logs' log-delivery service
  # (delivery.logs.amazonaws.com) must be explicitly granted GenerateDataKey
  # and Decrypt on this key, or delivery to a KMS-encrypted destination
  # bucket fails silently on real AWS -- an omission that would only surface
  # the first time an actual flow record needed to be written, not at
  # `terraform apply` time. Scoped with a StringEquals condition tying the
  # grant to this specific flow log's source ARN so no other account's flow
  # logs (or any other AWS-account use of this same service principal)
  # could use this key.
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
      {
        Sid    = "AllowVPCFlowLogsDelivery"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
    ]
  })

  tags = {
    Name = "${var.name_prefix}-${var.environment}-flow-logs-key"
  }
}

resource "aws_kms_alias" "flow_logs" {
  name          = "alias/${var.name_prefix}-${var.environment}-flow-logs"
  target_key_id = aws_kms_key.flow_logs.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.flow_logs.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id

  rule {
    id     = "flow-logs-transition-and-expire"
    status = "Enabled"

    filter {}

    # Abort any multipart upload S3 never completed after a week -- a
    # partial upload from an interrupted flow-log delivery would otherwise
    # sit in the bucket forever, silently billed and never surfaced by
    # anything this stack's own outputs describe.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    transition {
      days          = var.flow_log_transition_days
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = var.flow_log_retention_days
    }
  }
}

# The flow log itself. traffic_type = ALL (accepted and rejected traffic —
# an incident investigation needs both: a rejected connection is often the
# more interesting one) delivered to the bucket above.
#
# log_format is set explicitly rather than left as AWS's default. The
# default format omits fields this estate's threat model actually needs for
# incident work — notably account-id (which account a flow crossed, load-
# bearing the moment this pattern is copied into a real multi-account AWS
# org) and az-id/flow-direction (which side of a connection this record
# describes). Choosing the fields deliberately, and naming here why each
# group is included, is the difference between having flow logs and having
# flow logs that can actually answer an incident question — the exact
# distinction this plan's objective calls out. `$${...}` (doubled `$`) is
# Terraform's escape for a literal `${...}` in the resulting string; AWS
# resolves these placeholders at flow-log-delivery time, not Terraform at
# plan time.
resource "aws_flow_log" "this" {
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "s3"
  log_destination      = aws_s3_bucket.flow_logs.arn

  log_format = join(" ", [
    "$${version}",
    "$${account-id}", # which AWS account this flow crossed — the field a multi-account org cannot investigate without
    "$${vpc-id}",
    "$${subnet-id}",
    "$${interface-id}",
    "$${srcaddr}", "$${dstaddr}",
    "$${srcport}", "$${dstport}",
    "$${protocol}",
    "$${packets}", "$${bytes}",
    "$${start}", "$${end}",
    "$${action}", # ACCEPT or REJECT — the rejected side of a connection is often the more interesting one
    "$${log-status}",
    "$${flow-direction}", # ingress or egress — which side of a connection this record describes
    "$${az-id}",          # which availability zone, distinct from subnet-id, for the per-AZ NAT/route topology this module builds
  ])

  tags = {
    Name = "${var.name_prefix}-${var.environment}-vpc-flow-log"
  }

  # Querying these logs with Athena (the AWS service, unrelated to this
  # project's own "Athena" name) is the natural next step for turning this
  # bucket into something a human can actually run an incident query
  # against — deliberately out of this phase's scope (D-27); it belongs in
  # this phase's study notes, not as Terraform here.
}
