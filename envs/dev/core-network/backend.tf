# backend.tf — envs/dev/core-network (Plan 02-01, Task 1; CONTEXT.md D-17,
# D-29, D-30, IAC-02).
#
# This stack's backend is deliberately REMOTE (S3, LocalStack-backed) —
# the opposite of governance/main.tf's deliberately LOCAL backend. That
# earlier file's own header comment explains why (governance tracks a real,
# persistent GitHub org; this stack tracks resources in a free-tier
# LocalStack account that a restart wipes together with its state, which is
# the coherent behaviour for that tier — see
# docs/localstack-service-coverage.md's "Where state lives, and why").
#
# use_lockfile = true is Terraform's native S3 conditional-write locking
# (GA since 1.11) — no dynamodb_table argument anywhere in this file or any
# other env root. That argument is exactly what IAC-02 exists to remove.
#
# Credentials are NOT literals here. The AWS provider (provider.tf) and this
# backend both read AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY from the
# process environment — see scripts/tf-env.sh for the local-run helper and
# its header comment for why those values are non-secret by construction
# (D-13, D-16).
terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # resolved 6.57.1 via `terraform init` at execution time (2026-08-03)
    }
  }

  backend "s3" {
    bucket = "athena-tfstate-dev" # D-17: one bucket per env account
    key    = "core-network/terraform.tfstate"
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

# Plan 02-09 concurrency-queue drill: comment-only touch proving the
# plan job (dev) is scheduled while an apply (dev) is in flight (2026-08-04T04:22:49Z).
# This PR is closed without merging once the evidence is captured --
# no config change is intended, only a real pull_request event on a
# path detect-changes' dorny/paths-filter matches for dev.
