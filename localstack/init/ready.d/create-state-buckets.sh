#!/usr/bin/env bash
# create-state-buckets.sh — state-bucket bootstrap for the Phase 2+ AWS
# stacks (Plan 02-01, Task 1; CONTEXT.md D-18).
#
# Mounted read-only at /etc/localstack/init/ready.d/create-state-buckets.sh
# (see ../../docker-compose.yml's volumes: entry). LocalStack's init-hook
# stages run in this fixed order: boot.d -> start.d -> ready.d -> shutdown.d
# (docs.localstack.cloud/aws/capabilities/config/initialization-hooks/).
# This hook deliberately lives in ready.d, not boot.d or start.d: ready.d
# fires only after LocalStack reports its own edge/service layer is actually
# serving requests, and this script's first real call is an s3api head-bucket
# — a boot.d or start.d hook would race the S3 provider still coming up and
# fail non-deterministically on a cold container start.
#
# For each of dev/stg/prod, this exports that env's simulated 12-digit
# account id as AWS_ACCESS_KEY_ID before calling s3api: LocalStack derives
# the account namespace a request lands in from the access key on the
# request (not from a separate "account" concept), which is the mechanism
# D-16's account-per-env simulation rides on. Each env's bucket is therefore
# created *inside that env's own simulated account*, not a shared default
# account — the same namespacing envs/<env>/core-network's backend.tf and
# provider.tf read via scripts/tf-env.sh at apply time.
#
# check-before-create (mirrors ansible/roles/bootstrap-localstack's
# fail-loudly-with-a-remediation-command discipline, applied here to a
# create-only op instead of a fail): head-bucket is used as the existence
# probe so a container restart with PERSISTENCE=0 always recreates every
# bucket fresh, while a container that somehow already has the bucket
# (persistence enabled, or a re-run of this hook) never errors on a
# double-create.
#
# Prefers awslocal, falling back to `aws --endpoint-url` exactly as
# scripts/verify-localstack.sh's s3_cmd() already does — awslocal is not
# guaranteed present inside the LocalStack image's init-hook execution
# environment the same way it is on the host.
set -euo pipefail

LS_ENDPOINT="http://localhost:4566"

declare -A ACCOUNT_IDS=(
  [dev]="111111111111"
  [stg]="222222222222"
  [prod]="333333333333"
)

s3_cmd() {
  if command -v awslocal >/dev/null 2>&1; then
    awslocal "$@"
  else
    aws --endpoint-url "${LS_ENDPOINT}" "$@"
  fi
}

for env in dev stg prod; do
  bucket="athena-tfstate-${env}"
  account_id="${ACCOUNT_IDS[${env}]}"

  # LocalStack namespaces the request by the access key on it, not a
  # separately-configured "account" field — this export is the entire
  # mechanism, not a credential in any authorising sense (see
  # scripts/tf-env.sh's header for the same statement made to humans).
  export AWS_ACCESS_KEY_ID="${account_id}"
  export AWS_SECRET_ACCESS_KEY="${account_id}"
  export AWS_DEFAULT_REGION="us-east-1"

  if s3_cmd s3api head-bucket --bucket "${bucket}" >/dev/null 2>&1; then
    echo "[create-state-buckets] ${bucket} (account ${account_id}) already exists, skipping create"
  else
    echo "[create-state-buckets] creating ${bucket} in simulated account ${account_id}"
    s3_cmd s3 mb "s3://${bucket}"
    s3_cmd s3api put-bucket-versioning --bucket "${bucket}" --versioning-configuration Status=Enabled
  fi
done

echo "[create-state-buckets] done: athena-tfstate-{dev,stg,prod} present and versioned."
