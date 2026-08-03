#!/usr/bin/env bash
# verify-network.sh — IAC-04 output-driven awslocal verification for the
# Core/Network Terraform stack (Plan 02-01, Task 2).
#
# D-23: this script reads `terraform output -json` from an applied env root
# and asserts every named output actually exists in LocalStack via a real
# `describe-*` call — apply green + resource missing must be a hard FAIL,
# never a silent pass. It deliberately never reads `/_localstack/health`:
# that endpoint reports which service *implementations* are loaded, not
# which are licensed or functional (this project already live-verified that
# exact trap for four services — rds/elasticache/cloudfront/eks — and
# recorded it in docs/localstack-service-coverage.md; a service showing
# "available" there told us nothing about whether a real API call would
# actually succeed). A describe call is the only thing this script trusts.
#
# Deliberately not using `set -e` (mirrors verify-localstack.sh /
# verify-governance.sh): every fallible command is captured into a variable
# first so one failing check never aborts the ones after it;
# scripts/verify.sh (this script's dispatcher) is what turns any FAIL here
# into a non-zero process exit.
#
# Usage:
#   scripts/verify-network.sh          # every envs/*/core-network directory
#   scripts/verify-network.sh dev      # only envs/dev/core-network
#
# Extension point (Plans 02-03 and 02-05 add to this list as
# modules/core-network grows beyond a single aws_vpc): subnet ids, nat
# gateway ids, route table ids, vpc endpoint id, flow-logs bucket, baseline
# security group ids. Each new output gets its own assertion block below,
# following the same non-vacuous / identity / read-only shape as vpc_id.
#
# Multi-valued outputs (subnet ids, NAT ids, route table ids, ...) are always
# compared as UNORDERED SETS (sort both sides) — the describe API makes no
# ordering guarantee for a multi-id response, so a sequence comparison would
# make this verifier flip on API response order rather than on reality.

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

# aws_ls() always talks to LocalStack directly with whatever
# AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY are currently exported (the
# per-env account credentials this script sets before each env's block) —
# awslocal, when present, ignores an explicit --endpoint-url the same way
# aws_ls's own env-based auth already works, so both paths honor the
# currently-exported account.
aws_ls() {
  if [ -n "${AWSLOCAL_BIN}" ]; then
    "${AWSLOCAL_BIN}" "$@" 2>&1
  else
    aws --endpoint-url "${LS_ENDPOINT}" "$@" 2>&1
  fi
}

# ---------------------------------------------------------------------------
# Discover env roots: every envs/<env>/core-network directory that exists,
# optionally filtered to a single env name. Not finding the requested
# filter, or finding zero env roots at all, is itself asserted below (a
# vacuous discovery is exactly the failure IAC-04 exists to prevent).
# ---------------------------------------------------------------------------
mapfile -t ENV_DIRS < <(find "${REPO_ROOT}/envs" -mindepth 2 -maxdepth 2 -type d -name 'core-network' 2>/dev/null | sort)

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
    check "envs/${FILTER_ENV}/core-network exists" 1 "no such directory under ${REPO_ROOT}/envs"
  else
    check "at least one envs/*/core-network directory exists" 1 "no envs/*/core-network directories found under ${REPO_ROOT}/envs"
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
    # FAIL here — never a silent "0 passed, 0 failed" green. Every
    # subsequent assertion for this env is skipped (there is nothing to
    # assert against), but the FAIL is still counted.
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

    # -------------------------------------------------------------------
    # vpc_id: identity, not existence. The describe call's returned
    # VpcId must equal (grep -Fxq) the exact id Terraform emitted — a
    # describe that happens to return some other VPC of the same type
    # would still fail this check.
    # -------------------------------------------------------------------
    VPC_ID="$(printf '%s' "${OUTPUT_JSON}" | jq -r '.vpc_id.value // empty' 2>/dev/null)"
    if [ -z "${VPC_ID}" ]; then
      check "${env_name}: vpc_id output is present" 1 \
        "terraform output -json has no .vpc_id.value key"
      continue
    fi

    DESCRIBE_VPC_ID="$(aws_ls ec2 describe-vpcs --vpc-ids "${VPC_ID}" --query 'Vpcs[0].VpcId' --output text)"
    if printf '%s' "${DESCRIBE_VPC_ID}" | grep -Fxq "${VPC_ID}"; then
      check "${env_name}: vpc_id (${VPC_ID}) confirmed real via ec2 describe-vpcs" 0
    else
      check "${env_name}: vpc_id (${VPC_ID}) confirmed real via ec2 describe-vpcs" 1 \
        "expected=[${VPC_ID}] observed=[${DESCRIBE_VPC_ID}]"
    fi

    # -------------------------------------------------------------------
    # Subnets (Plan 02-03, Task 1): for each of the three tiers, assert the
    # subnet id set matches ec2 describe-subnets as an UNORDERED SET, then
    # assert each returned subnet's CIDR matches what Terraform's state
    # records and that it hangs off this env's VPC (not some other one).
    #
    # `terraform show -json` (no plan-file argument) reports the current
    # STATE as JSON, not a plan — this is where each subnet's planned CIDR
    # is read from, since there is no dedicated verification-only output
    # for it. Resources are collected recursively across root_module and
    # any nested child_modules so this works regardless of module nesting.
    # -------------------------------------------------------------------
    STATE_JSON="$(cd "${dir}" && terraform show -json 2>&1)"
    STATE_EXIT=$?
    if [ "${STATE_EXIT}" -ne 0 ]; then
      check "${env_name}: terraform show -json succeeds (needed for subnet CIDR assertions)" 1 \
        "exit=${STATE_EXIT} output=[${STATE_JSON:0:200}]"
    else
      ALL_RESOURCES="$(printf '%s' "${STATE_JSON}" | jq -c '[.values.root_module | .. | .resources? // empty | .[]?]' 2>/dev/null)"

      for tier_pair in "public:public_subnet_ids" "private-app:private_app_subnet_ids" "private-data:private_data_subnet_ids"; do
        tier="${tier_pair%%:*}"
        out_key="${tier_pair##*:}"

        EXPECTED_IDS_JSON="$(printf '%s' "${OUTPUT_JSON}" | jq -c --arg k "${out_key}" '.[$k].value // []' 2>/dev/null)"
        EXPECTED_COUNT="$(printf '%s' "${EXPECTED_IDS_JSON}" | jq 'length' 2>/dev/null)"

        if [ -z "${EXPECTED_COUNT}" ] || [ "${EXPECTED_COUNT}" -eq 0 ] 2>/dev/null; then
          check "${env_name}: ${out_key} output is present and non-empty" 1 \
            "terraform output -json has no non-empty .${out_key}.value"
          continue
        fi

        EXPECTED_IDS_SORTED="$(printf '%s' "${EXPECTED_IDS_JSON}" | jq -r '.[]' 2>/dev/null | sort)"
        EXPECTED_IDS_SPACE="$(printf '%s' "${EXPECTED_IDS_JSON}" | jq -r '.[]' 2>/dev/null | tr '\n' ' ')"

        DESCRIBE_JSON="$(aws_ls ec2 describe-subnets --subnet-ids ${EXPECTED_IDS_SPACE} --output json)"
        OBSERVED_IDS_SORTED="$(printf '%s' "${DESCRIBE_JSON}" | jq -r '.Subnets[].SubnetId' 2>/dev/null | sort)"

        if [ -n "${OBSERVED_IDS_SORTED}" ] && [ "${EXPECTED_IDS_SORTED}" = "${OBSERVED_IDS_SORTED}" ]; then
          check "${env_name}: ${tier} subnet id set (${EXPECTED_COUNT}) matches ec2 describe-subnets, unordered" 0
        else
          check "${env_name}: ${tier} subnet id set matches ec2 describe-subnets, unordered" 1 \
            "expected=[${EXPECTED_IDS_SORTED}] observed=[${OBSERVED_IDS_SORTED}]"
        fi

        MISMATCH=""
        for sid in $(printf '%s' "${EXPECTED_IDS_JSON}" | jq -r '.[]' 2>/dev/null); do
          PLANNED_CIDR="$(printf '%s' "${ALL_RESOURCES}" | jq -r --arg id "${sid}" '.[] | select(.type=="aws_subnet" and .values.id==$id) | .values.cidr_block // empty' 2>/dev/null | head -1)"
          OBSERVED_CIDR="$(printf '%s' "${DESCRIBE_JSON}" | jq -r --arg id "${sid}" '.Subnets[] | select(.SubnetId==$id) | .CidrBlock // empty' 2>/dev/null)"
          OBSERVED_VPC="$(printf '%s' "${DESCRIBE_JSON}" | jq -r --arg id "${sid}" '.Subnets[] | select(.SubnetId==$id) | .VpcId // empty' 2>/dev/null)"

          if [ -z "${PLANNED_CIDR}" ] || [ "${PLANNED_CIDR}" != "${OBSERVED_CIDR}" ] || [ "${OBSERVED_VPC}" != "${VPC_ID}" ]; then
            MISMATCH="${MISMATCH} ${sid}(planned_cidr=${PLANNED_CIDR:-<none>} observed_cidr=${OBSERVED_CIDR:-<none>} observed_vpc=${OBSERVED_VPC:-<none>} expected_vpc=${VPC_ID})"
          fi
        done

        if [ -z "${MISMATCH}" ]; then
          check "${env_name}: ${tier} subnet CIDRs match Terraform state and hang off ${VPC_ID}" 0
        else
          check "${env_name}: ${tier} subnet CIDRs match Terraform state and hang off ${VPC_ID}" 1 \
            "mismatches:${MISMATCH}"
        fi
      done
    fi
  done
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
printf '[verify-network] %s passed, %s failed, %s total.\n' \
  "${PASS_COUNT}" "${FAIL_COUNT}" "$((PASS_COUNT + FAIL_COUNT))"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
