# provider.tf — envs/dev/core-network (Plan 02-01, Task 1; CONTEXT.md D-16,
# D-26).
#
# No access-key/secret-key arguments appear in this block at all, by design:
# the AWS provider's default credential chain already reads
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY straight out of the process
# environment when neither argument is set, exported by scripts/tf-env.sh
# locally or by dev's GitHub Environment variables in CI (D-13). This is the
# seam that makes a future real-AWS OIDC swap a configuration change rather
# than an edit to every env root — and it is why credentials never appear
# as HCL literals anywhere in this directory.
#
# default_tags carries the six mandatory estate tags (D-26) — written once,
# here, rather than per-resource. The full tagging standard, including the
# per-resource Protection tag on destroy-sensitive resources, is Plan 02-05's
# deliverable.
provider "aws" {
  region = "us-east-1"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    s3  = "http://localhost:4566"
    ec2 = "http://localhost:4566"
    iam = "http://localhost:4566"
    sts = "http://localhost:4566"
  }

  default_tags {
    tags = {
      Project     = "athena"
      Environment = "dev"
      Stack       = "core-network"
      ManagedBy   = "terraform"
      Owner       = "platform"
      CostCenter  = "athena-platform"
    }
  }
}
