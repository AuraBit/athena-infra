#!/usr/bin/env bash
# verify-data-storage.sh — IAC-04 output-driven awslocal verification for the
# Data/Storage Terraform stack (Plan 03-02, Task 2).
#
# Same house shape as verify-network.sh: `set -uo pipefail` (never `set -e`
# — one failing check must never abort the ones after it; scripts/verify.sh
# is what turns any FAIL here into a non-zero process exit), the check()
# helper copied verbatim, and the same PASS/FAIL summary/exit-code
# convention. Discovers every envs/*/data-storage directory that exists
# (mirrors verify-network.sh's newer "iterate every environment that
# exists" shape, not verify-localstack.sh's single-target original), so
# this script covers dev today and stg/prod the moment their env roots
# land, with zero edit to this file.
#
# Usage:
#   scripts/verify-data-storage.sh          # every envs/*/data-storage directory
#   scripts/verify-data-storage.sh dev       # only envs/dev/data-storage
#
# Three properties are load-bearing here (D-07's own verification-strategy
# text), not retrofitted:
#
#   1. Non-vacuous pass — an uninitialised env dir, or one whose
#      `terraform output -json` yields an empty object, is a hard FAIL,
#      never a silent "0 passed, 0 failed" green.
#   2. Real work, not a status call — the bucket assertion is a round trip:
#      write a small object with known content, read it back, compare
#      bytes, delete it. `head-bucket` alone only proves LocalStack
#      answered, not that the bucket stores and returns data.
#   3. Read-mostly and self-cleaning — the only write is the smoke object,
#      removed by a `trap cleanup EXIT` even if the script dies partway.
#      Two consecutive runs must produce identical PASS/FAIL counts and
#      leave the bucket with the same object count they found.
#
# Extension point (Phase 6): RDS instance identifiers, ElastiCache cluster
# endpoints, CloudFront distribution ids all get their own assertion block
# here, following this same non-vacuous / real-work / read-only shape, once
# modules/data-storage grows beyond the media bucket. Per
# docs/localstack-service-coverage.md, `rds`/`elasticache`/`cloudfront` are
# `code+docs-only` on the current LocalStack Hobby-tier account (license-
# gated) — Phase 6's own assertions for those resource types are expected
# to stay doc-verified rather than awslocal-verified until the OSS Program
# upgrade lands; see that document rather than restating its contents here.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
LS_ENDPOINT="http://localhost:4566"
FILTER_ENV="${1:-}"

declare -A ACCOUNT_IDS=(
  [dev]="111111111111"
  [stg]="222222222222"
  [prod]="333333333333"
)

PASS_COUNT=0
FAIL_COUNT=0

check() {
  local name="$1" status="$2" observed="${3:-}"
  if [ "${status}" -eq 0 ]; then
    printf '\033[32mPASS\033[0m  %s\n' "${name}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    printf '\033[31mFAIL\033[0m  %s\n' "${name}"
    printf '      observed: %s\n' "${observed}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

AWSLOCAL_BIN=""
if command -v awslocal >/dev/null 2>&1; then
  AWSLOCAL_BIN="awslocal"
fi

aws_ls() {
  if [ -n "${AWSLOCAL_BIN}" ]; then
    "${AWSLOCAL_BIN}" "$@" 2>&1
  else
    aws --endpoint-url "${LS_ENDPOINT}" "$@" 2>&1
  fi
}

# ---------------------------------------------------------------------------
# Smoke-object bookkeeping and cleanup trap. The key is namespaced per
# environment so a filtered single-env run and the full multi-env run never
# collide with each other's in-flight smoke object.
# ---------------------------------------------------------------------------
SMOKE_KEY_PREFIX="verify-data-storage-smoke"
declare -a CLEANUP_TARGETS=() # "bucket|key" pairs, populated as each env's round trip runs
SMOKE_TMP_UPLOAD="$(mktemp)"
SMOKE_TMP_DOWNLOAD="$(mktemp)"

cleanup() {
  local target bucket key
  for target in "${CLEANUP_TARGETS[@]:-}"; do
    [ -z "${target}" ] && continue
    bucket="${target%%|*}"
    key="${target##*|}"
    aws_ls s3 rm "s3://${bucket}/${key}" >/dev/null 2>&1 || true
  done
  rm -f "${SMOKE_TMP_UPLOAD}" "${SMOKE_TMP_DOWNLOAD}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Discover env roots: every envs/<env>/data-storage directory that exists,
# optionally filtered to a single env name.
# ---------------------------------------------------------------------------
mapfile -t ENV_DIRS < <(find "${REPO_ROOT}/envs" -mindepth 2 -maxdepth 2 -type d -name 'data-storage' 2>/dev/null | sort)

TARGET_DIRS=()
TARGET_ENVS=()
for dir in "${ENV_DIRS[@]}"; do
  env_name="$(basename "$(dirname "${dir}")")"
  if [ -z "${FILTER_ENV}" ] || [ "${env_name}" = "${FILTER_ENV}" ]; then
    TARGET_DIRS+=("${dir}")
    TARGET_ENVS+=("${env_name}")
  fi
done

if [ "${#TARGET_DIRS[@]}" -eq 0 ]; then
  if [ -n "${FILTER_ENV}" ]; then
    check "envs/${FILTER_ENV}/data-storage exists" 1 "no such directory under ${REPO_ROOT}/envs"
  else
    check "at least one envs/*/data-storage directory exists" 1 "no envs/*/data-storage directories found under ${REPO_ROOT}/envs"
  fi
else
  for idx in "${!TARGET_DIRS[@]}"; do
    dir="${TARGET_DIRS[${idx}]}"
    env_name="${TARGET_ENVS[${idx}]}"
    account_id="${ACCOUNT_IDS[${env_name}]:-}"

    if [ -z "${account_id}" ]; then
      check "${env_name}: known simulated account id" 1 \
        "no ACCOUNT_IDS entry for env '${env_name}' — add one to this script alongside tf-env.sh"
      continue
    fi

    # -------------------------------------------------------------------
    # Non-vacuous pass (IAC-04's core guard): an uninitialised env dir, or
    # one whose `terraform output -json` yields an empty object, is a hard
    # FAIL — never a silent "0 passed, 0 failed" green.
    # -------------------------------------------------------------------
    OUTPUT_JSON="$(cd "${dir}" && terraform output -json 2>&1)"
    OUTPUT_EXIT=$?

    if [ "${OUTPUT_EXIT}" -ne 0 ]; then
      check "${env_name}: terraform output -json succeeds (env is initialised and applied)" 1 \
        "exit=${OUTPUT_EXIT} output=[${OUTPUT_JSON:0:200}]"
      continue
    fi

    OUTPUT_KEY_COUNT="$(printf '%s' "${OUTPUT_JSON}" | jq -r 'keys | length' 2>/dev/null)" || OUTPUT_KEY_COUNT=""
    if [ -z "${OUTPUT_KEY_COUNT}" ] || [ "${OUTPUT_KEY_COUNT}" -eq 0 ] 2>/dev/null; then
      check "${env_name}: terraform output -json yields at least one output" 1 \
        "empty output set — an applied stack with zero outputs is a FAIL, never a vacuous green (IAC-04)"
      continue
    fi
    check "${env_name}: terraform output -json yields ${OUTPUT_KEY_COUNT} output(s), non-vacuous" 0

    export AWS_ACCESS_KEY_ID="${account_id}"
    export AWS_SECRET_ACCESS_KEY="${account_id}"
    export AWS_DEFAULT_REGION="us-east-1"

    MEDIA_BUCKET="$(printf '%s' "${OUTPUT_JSON}" | jq -r '.media_bucket_name.value // empty' 2>/dev/null)"
    if [ -z "${MEDIA_BUCKET}" ]; then
      check "${env_name}: media_bucket_name output is present" 1 \
        "terraform output -json has no .media_bucket_name.value key"
      continue
    fi

    # -------------------------------------------------------------------
    # Identity: the bucket this env's output names is a real bucket, not
    # merely one Terraform's state claims exists.
    # -------------------------------------------------------------------
    HEAD_BUCKET_OUT="$(aws_ls s3api head-bucket --bucket "${MEDIA_BUCKET}" 2>&1)"
    HEAD_BUCKET_EXIT=$?
    check "${env_name}: media bucket ${MEDIA_BUCKET} exists (s3api head-bucket)" "${HEAD_BUCKET_EXIT}" "${HEAD_BUCKET_OUT}"

    # -------------------------------------------------------------------
    # Real work, not a status call: write a smoke object with known
    # content, read it back, compare bytes, delete it. The observed line
    # on PASS shows the actual retrieved content matching what was
    # written — not merely that the calls returned success — so a reader
    # of this script's output can see the round trip happened, not just
    # trust that it did.
    # -------------------------------------------------------------------
    SMOKE_KEY="${SMOKE_KEY_PREFIX}-${env_name}.txt"
    SMOKE_BODY="athena-data-storage-smoke-${env_name}-$(date +%s)-$$"
    printf '%s' "${SMOKE_BODY}" >"${SMOKE_TMP_UPLOAD}"
    CLEANUP_TARGETS+=("${MEDIA_BUCKET}|${SMOKE_KEY}")

    ROUNDTRIP_OK=1
    ROUNDTRIP_OBSERVED=""
    if aws_ls s3 cp "${SMOKE_TMP_UPLOAD}" "s3://${MEDIA_BUCKET}/${SMOKE_KEY}" >/dev/null 2>&1 \
      && aws_ls s3 cp "s3://${MEDIA_BUCKET}/${SMOKE_KEY}" "${SMOKE_TMP_DOWNLOAD}" >/dev/null 2>&1; then
      RETRIEVED_BODY="$(cat "${SMOKE_TMP_DOWNLOAD}" 2>/dev/null)"
      if [ "${RETRIEVED_BODY}" = "${SMOKE_BODY}" ]; then
        ROUNDTRIP_OK=0
        ROUNDTRIP_OBSERVED="written=[${SMOKE_BODY}] retrieved=[${RETRIEVED_BODY}] (match)"
      else
        ROUNDTRIP_OBSERVED="written=[${SMOKE_BODY}] retrieved=[${RETRIEVED_BODY}] (MISMATCH)"
      fi
    else
      ROUNDTRIP_OBSERVED="put/get failed (see aws_ls output above)"
    fi

    if [ "${ROUNDTRIP_OK}" -eq 0 ]; then
      check "${env_name}: media bucket object round trip — retrieved body matches written body (${ROUNDTRIP_OBSERVED})" 0
    else
      check "${env_name}: media bucket object round trip — retrieved body matches written body" 1 "${ROUNDTRIP_OBSERVED}"
    fi

    # Explicit delete now (not just left to the exit trap) — this is what
    # makes the "leaves no residue" / "identical object count on a second
    # run" acceptance criterion true even for a script that completes
    # normally, not merely for one that dies partway.
    aws_ls s3 rm "s3://${MEDIA_BUCKET}/${SMOKE_KEY}" >/dev/null 2>&1 || true

    # -------------------------------------------------------------------
    # Configuration properties, each independently confirmed via a real
    # API call — an apply that reports success against a bucket LocalStack
    # silently failed to fully configure is exactly the fake-success class
    # IAC-04 exists to catch.
    # -------------------------------------------------------------------
    VERSIONING_STATUS="$(aws_ls s3api get-bucket-versioning --bucket "${MEDIA_BUCKET}" --query 'Status' --output text 2>/dev/null)"
    if [ "${VERSIONING_STATUS}" = "Enabled" ]; then
      check "${env_name}: media bucket versioning is Enabled" 0
    else
      check "${env_name}: media bucket versioning is Enabled" 1 \
        "observed Status=[${VERSIONING_STATUS}]"
    fi

    ENCRYPTION_JSON="$(aws_ls s3api get-bucket-encryption --bucket "${MEDIA_BUCKET}" --output json 2>/dev/null)"
    ENCRYPTION_ALGO="$(printf '%s' "${ENCRYPTION_JSON}" | jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm // empty' 2>/dev/null)"
    if [ "${ENCRYPTION_ALGO}" = "aws:kms" ] || [ "${ENCRYPTION_ALGO}" = "AES256" ]; then
      check "${env_name}: media bucket has server-side encryption configured (${ENCRYPTION_ALGO})" 0
    else
      check "${env_name}: media bucket has server-side encryption configured" 1 \
        "observed=[${ENCRYPTION_JSON}]"
    fi

    PAB_JSON="$(aws_ls s3api get-public-access-block --bucket "${MEDIA_BUCKET}" --output json 2>/dev/null)"
    PAB_ALL_TRUE="$(printf '%s' "${PAB_JSON}" | jq -r '
      .PublicAccessBlockConfiguration
      | (.BlockPublicAcls == true and .BlockPublicPolicy == true and .IgnorePublicAcls == true and .RestrictPublicBuckets == true)
    ' 2>/dev/null)"
    if [ "${PAB_ALL_TRUE}" = "true" ]; then
      check "${env_name}: media bucket public access block is fully on (all four settings true)" 0
    else
      check "${env_name}: media bucket public access block is fully on (all four settings true)" 1 \
        "observed=[${PAB_JSON}]"
    fi

    TAGGING_JSON="$(aws_ls s3api get-bucket-tagging --bucket "${MEDIA_BUCKET}" --output json 2>/dev/null)"
    TAG_KEYS_SORTED="$(printf '%s' "${TAGGING_JSON}" | jq -r '.TagSet[].Key' 2>/dev/null | sort | tr '\n' ' ')"
    MISSING_TAGS=""
    for required_tag in Project Environment Stack ManagedBy Owner CostCenter Protection; do
      if ! printf '%s' "${TAGGING_JSON}" | jq -e --arg k "${required_tag}" '.TagSet[] | select(.Key == $k)' >/dev/null 2>&1; then
        MISSING_TAGS="${MISSING_TAGS} ${required_tag}"
      fi
    done
    if [ -z "${MISSING_TAGS}" ]; then
      check "${env_name}: media bucket carries all six mandatory tags plus Protection (observed keys: ${TAG_KEYS_SORTED})" 0
    else
      check "${env_name}: media bucket carries all six mandatory tags plus Protection" 1 \
        "missing:${MISSING_TAGS} observed=[${TAG_KEYS_SORTED}]"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
printf '[verify-data-storage] %s passed, %s failed, %s total.\n' \
  "${PASS_COUNT}" "${FAIL_COUNT}" "$((PASS_COUNT + FAIL_COUNT))"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
