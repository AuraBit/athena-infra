# backend.tf — envs/prod/data-storage (Plan 03-02, Task 2; CONTEXT.md D-07).
#
# Copied verbatim from envs/dev/core-network/backend.tf's shape (D-07: reuse
# Phase 2's backend/locking/CI pattern verbatim) — same dev state bucket,
# same native S3 lockfile locking, same LocalStack endpoint/skip flags, only
# the state key changes. No dynamodb_table argument anywhere in this file or
# any other env root in this stack.
#
# Credentials are NOT literals here — same seam as core-network: the AWS
# provider (provider.tf) and this backend both read AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY from the process environment (scripts/tf-env.sh
# locally, per-environment GitHub Environment variables in CI).
terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket = "athena-tfstate-prod" # D-17: one bucket per env account, same as core-network
    key    = "data-storage/terraform.tfstate"
    region = "us-east-1"

    # IAC-02 — native S3 lockfile locking; no lock-table argument of any kind
    # appears anywhere in this file.
    use_lockfile = true

    endpoints = {
      s3 = "http://localhost:4566"
    }
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    use_path_style              = true
  }
}
