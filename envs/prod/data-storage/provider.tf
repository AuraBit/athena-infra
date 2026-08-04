# provider.tf — envs/prod/data-storage (Plan 03-02, Task 2; CONTEXT.md D-16,
# D-26).
#
# Reproduces envs/dev/core-network/provider.tf's shape (D-07), scoped to the
# endpoints this stack actually uses: s3 for the bucket itself, sts for
# media_bucket.tf's data "aws_caller_identity" (the media key's account-root
# policy grant), kms for the media bucket's encryption key. No
# access-key/secret-key literals — the AWS provider's default credential
# chain reads AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY from the process
# environment.
#
# default_tags carries the six mandatory estate tags (D-26), Stack =
# "data-storage" distinguishing this stack's resources from core-network's
# in the same simulated account.
provider "aws" {
  region = "us-east-1"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    s3  = "http://localhost:4566"
    sts = "http://localhost:4566"
    # kms: media_bucket.tf's aws_kms_key needs this override for the same
    # reason core-network/provider.tf documents for its own flow-logs key —
    # without it the AWS provider silently sends KMS calls to the real
    # kms.us-east-1.amazonaws.com using this stack's fake LocalStack
    # credentials.
    kms = "http://localhost:4566"
  }

  default_tags {
    tags = {
      Project     = "athena"
      Environment = "prod"
      Stack       = "data-storage"
      ManagedBy   = "terraform"
      Owner       = "platform"
      CostCenter  = "athena-platform"
    }
  }
}
