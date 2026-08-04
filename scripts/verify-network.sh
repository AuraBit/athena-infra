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

    # -------------------------------------------------------------------
    # Internet gateway, NAT egress, per-tier routes (Plan 02-03, Task 2).
    # -------------------------------------------------------------------
    IGW_ID="$(printf '%s' "${OUTPUT_JSON}" | jq -r '.internet_gateway_id.value // empty' 2>/dev/null)"
    if [ -z "${IGW_ID}" ]; then
      check "${env_name}: internet_gateway_id output is present" 1 \
        "terraform output -json has no .internet_gateway_id.value key"
    else
      IGW_DESCRIBE="$(aws_ls ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=${VPC_ID}" --output json)"
      IGW_OBSERVED_ID="$(printf '%s' "${IGW_DESCRIBE}" | jq -r '.InternetGateways[0].InternetGatewayId // empty' 2>/dev/null)"
      IGW_COUNT="$(printf '%s' "${IGW_DESCRIBE}" | jq -r '.InternetGateways | length' 2>/dev/null)"
      if [ "${IGW_COUNT}" = "1" ] && [ "${IGW_OBSERVED_ID}" = "${IGW_ID}" ]; then
        check "${env_name}: internet_gateway_id (${IGW_ID}) attached to ${VPC_ID}, confirmed via ec2 describe-internet-gateways" 0
      else
        check "${env_name}: internet_gateway_id attached to ${VPC_ID}" 1 \
          "expected=[${IGW_ID}] observed_count=[${IGW_COUNT}] observed_id=[${IGW_OBSERVED_ID}]"
      fi
    fi

    NAT_IDS_JSON="$(printf '%s' "${OUTPUT_JSON}" | jq -c '.nat_gateway_ids.value // []' 2>/dev/null)"
    NAT_COUNT="$(printf '%s' "${NAT_IDS_JSON}" | jq 'length' 2>/dev/null)"
    if [ -z "${NAT_COUNT}" ] || [ "${NAT_COUNT}" -eq 0 ] 2>/dev/null; then
      check "${env_name}: nat_gateway_ids output is present and non-empty" 1 \
        "terraform output -json has no non-empty .nat_gateway_ids.value"
    else
      NAT_IDS_SORTED="$(printf '%s' "${NAT_IDS_JSON}" | jq -r '.[]' 2>/dev/null | sort)"
      NAT_IDS_SPACE="$(printf '%s' "${NAT_IDS_JSON}" | jq -r '.[]' 2>/dev/null | tr '\n' ' ')"

      NAT_DESCRIBE="$(aws_ls ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${VPC_ID}" --output json)"
      NAT_OBSERVED_SORTED="$(printf '%s' "${NAT_DESCRIBE}" | jq -r '.NatGateways[].NatGatewayId' 2>/dev/null | sort)"

      if [ -n "${NAT_OBSERVED_SORTED}" ] && [ "${NAT_IDS_SORTED}" = "${NAT_OBSERVED_SORTED}" ]; then
        check "${env_name}: nat_gateway_ids set (${NAT_COUNT}) matches ec2 describe-nat-gateways, unordered" 0
      else
        check "${env_name}: nat_gateway_ids set matches ec2 describe-nat-gateways, unordered" 1 \
          "expected=[${NAT_IDS_SORTED}] observed=[${NAT_OBSERVED_SORTED}]"
      fi

      NAT_NOT_AVAILABLE="$(printf '%s' "${NAT_DESCRIBE}" | jq -r '[.NatGateways[] | select(.State != "available") | .NatGatewayId] | join(",")' 2>/dev/null)"
      if [ -z "${NAT_NOT_AVAILABLE}" ]; then
        check "${env_name}: every NAT gateway (${NAT_COUNT}) reports state 'available'" 0
      else
        check "${env_name}: every NAT gateway reports state 'available'" 1 \
          "not available: ${NAT_NOT_AVAILABLE}"
      fi

      # private-app route tables: each must carry exactly one 0.0.0.0/0
      # route whose target is a NAT gateway id present in nat_gateway_ids.
      APP_RT_IDS_JSON="$(printf '%s' "${OUTPUT_JSON}" | jq -c '.private_app_route_table_ids.value // []' 2>/dev/null)"
      APP_RT_COUNT="$(printf '%s' "${APP_RT_IDS_JSON}" | jq 'length' 2>/dev/null)"
      if [ -z "${APP_RT_COUNT}" ] || [ "${APP_RT_COUNT}" -eq 0 ] 2>/dev/null; then
        check "${env_name}: private_app_route_table_ids output is present and non-empty" 1 \
          "terraform output -json has no non-empty .private_app_route_table_ids.value"
      else
        APP_RT_MISMATCH=""
        for rtid in $(printf '%s' "${APP_RT_IDS_JSON}" | jq -r '.[]' 2>/dev/null); do
          RT_DESCRIBE="$(aws_ls ec2 describe-route-tables --route-table-ids "${rtid}" --output json)"
          RT_NAT_TARGET="$(printf '%s' "${RT_DESCRIBE}" | jq -r --arg cidr "0.0.0.0/0" '.RouteTables[0].Routes[]? | select(.DestinationCidrBlock==$cidr) | .NatGatewayId // empty' 2>/dev/null)"
          if [ -z "${RT_NAT_TARGET}" ] || ! printf '%s' "${NAT_IDS_SORTED}" | grep -Fxq "${RT_NAT_TARGET}"; then
            APP_RT_MISMATCH="${APP_RT_MISMATCH} ${rtid}(nat_target=${RT_NAT_TARGET:-<none>})"
          fi
        done
        if [ -z "${APP_RT_MISMATCH}" ]; then
          check "${env_name}: every private-app route table (${APP_RT_COUNT}) has a 0.0.0.0/0 route to a known NAT gateway" 0
        else
          check "${env_name}: every private-app route table has a 0.0.0.0/0 route to a known NAT gateway" 1 \
            "mismatches:${APP_RT_MISMATCH}"
        fi
      fi

      # private-data route tables: none may carry a 0.0.0.0/0 route at all —
      # that absence is provable via a real describe call, which is exactly
      # what a plan file cannot do.
      DATA_RT_IDS_JSON="$(printf '%s' "${OUTPUT_JSON}" | jq -c '.private_data_route_table_ids.value // []' 2>/dev/null)"
      DATA_RT_COUNT="$(printf '%s' "${DATA_RT_IDS_JSON}" | jq 'length' 2>/dev/null)"
      if [ -z "${DATA_RT_COUNT}" ] || [ "${DATA_RT_COUNT}" -eq 0 ] 2>/dev/null; then
        check "${env_name}: private_data_route_table_ids output is present and non-empty" 1 \
          "terraform output -json has no non-empty .private_data_route_table_ids.value"
      else
        DATA_RT_LEAK=""
        for rtid in $(printf '%s' "${DATA_RT_IDS_JSON}" | jq -r '.[]' 2>/dev/null); do
          RT_DESCRIBE="$(aws_ls ec2 describe-route-tables --route-table-ids "${rtid}" --output json)"
          RT_HAS_DEFAULT="$(printf '%s' "${RT_DESCRIBE}" | jq -r --arg cidr "0.0.0.0/0" '[.RouteTables[0].Routes[]? | select(.DestinationCidrBlock==$cidr)] | length' 2>/dev/null)"
          if [ -n "${RT_HAS_DEFAULT}" ] && [ "${RT_HAS_DEFAULT}" != "0" ]; then
            DATA_RT_LEAK="${DATA_RT_LEAK} ${rtid}(0.0.0.0/0 route count=${RT_HAS_DEFAULT})"
          fi
        done
        if [ -z "${DATA_RT_LEAK}" ]; then
          check "${env_name}: no private-data route table (${DATA_RT_COUNT}) carries a 0.0.0.0/0 route" 0
        else
          check "${env_name}: no private-data route table carries a 0.0.0.0/0 route" 1 \
            "leaked default route(s):${DATA_RT_LEAK}"
        fi
      fi

      # ---------------------------------------------------------------
      # S3 gateway VPC endpoint (Plan 02-03, Task 3): attached route-table
      # id set must equal the union of private_app_route_table_ids and
      # private_data_route_table_ids, compared sorted. Per the plan's own
      # instruction: if LocalStack's EC2 emulation does not implement
      # gateway endpoints at the fidelity these assertions need, the
      # assertions themselves are NOT weakened — a failure here is a real
      # signal, recorded in the plan's SUMMARY verification notes rather
      # than silently softened (a softened assertion is exactly the
      # fake-success failure IAC-04 exists to catch).
      # ---------------------------------------------------------------
      S3_EP_ID="$(printf '%s' "${OUTPUT_JSON}" | jq -r '.s3_vpc_endpoint_id.value // empty' 2>/dev/null)"
      if [ -z "${S3_EP_ID}" ]; then
        check "${env_name}: s3_vpc_endpoint_id output is present" 1 \
          "terraform output -json has no .s3_vpc_endpoint_id.value key"
      else
        EP_DESCRIBE="$(aws_ls ec2 describe-vpc-endpoints --vpc-endpoint-ids "${S3_EP_ID}" --output json)"
        EP_TYPE="$(printf '%s' "${EP_DESCRIBE}" | jq -r '.VpcEndpoints[0].VpcEndpointType // empty' 2>/dev/null)"
        EP_SERVICE="$(printf '%s' "${EP_DESCRIBE}" | jq -r '.VpcEndpoints[0].ServiceName // empty' 2>/dev/null)"
        EP_STATE="$(printf '%s' "${EP_DESCRIBE}" | jq -r '.VpcEndpoints[0].State // empty' 2>/dev/null)"

        if [ "${EP_TYPE}" = "Gateway" ] && [[ "${EP_SERVICE}" == *.s3 ]] && [ "${EP_STATE}" = "available" ]; then
          check "${env_name}: s3_vpc_endpoint_id (${S3_EP_ID}) is a Gateway endpoint for ${EP_SERVICE}, state available" 0
        else
          check "${env_name}: s3_vpc_endpoint_id is a Gateway endpoint for an s3 service, state available" 1 \
            "type=[${EP_TYPE}] service=[${EP_SERVICE}] state=[${EP_STATE}]"
        fi

        EXPECTED_RT_UNION_SORTED="$(printf '%s\n%s\n' \
          "$(printf '%s' "${APP_RT_IDS_JSON:-[]}" | jq -r '.[]' 2>/dev/null)" \
          "$(printf '%s' "${DATA_RT_IDS_JSON:-[]}" | jq -r '.[]' 2>/dev/null)" \
          | sed '/^$/d' | sort)"
        OBSERVED_RT_SORTED="$(printf '%s' "${EP_DESCRIBE}" | jq -r '.VpcEndpoints[0].RouteTableIds[]?' 2>/dev/null | sort)"

        if [ -n "${OBSERVED_RT_SORTED}" ] && [ "${EXPECTED_RT_UNION_SORTED}" = "${OBSERVED_RT_SORTED}" ]; then
          check "${env_name}: s3 endpoint's RouteTableIds equals the union of private_app + private_data route tables, unordered" 0
        else
          check "${env_name}: s3 endpoint's RouteTableIds equals the union of private_app + private_data route tables, unordered" 1 \
            "expected=[${EXPECTED_RT_UNION_SORTED}] observed=[${OBSERVED_RT_SORTED}]"
        fi
      fi
    fi

    # -------------------------------------------------------------------
    # VPC flow logs into the per-env flow-logs bucket (Plan 02-05, Task 2;
    # D-27). Bucket existence/versioning/public-access-block/lifecycle are
    # each asserted independently via a real API call rather than inferred
    # from `terraform apply`'s exit code — an apply that reports success
    # against a bucket LocalStack silently failed to fully configure is
    # exactly the fake-success class IAC-04 exists to catch. If LocalStack's
    # S3/EC2 emulation genuinely does not implement one of these calls at
    # the fidelity needed, that is a real FAIL here, recorded in the plan's
    # SUMMARY and docs/localstack-service-coverage.md (Plan 02-11) — never
    # silently weakened to make this script pass.
    # -------------------------------------------------------------------
    FLOW_BUCKET="$(printf '%s' "${OUTPUT_JSON}" | jq -r '.flow_logs_bucket_name.value // empty' 2>/dev/null)"
    if [ -z "${FLOW_BUCKET}" ]; then
      check "${env_name}: flow_logs_bucket_name output is present" 1 \
        "terraform output -json has no .flow_logs_bucket_name.value key"
    else
      HEAD_BUCKET_OUT="$(aws_ls s3api head-bucket --bucket "${FLOW_BUCKET}" 2>&1)"
      HEAD_BUCKET_EXIT=$?
      check "${env_name}: flow-logs bucket ${FLOW_BUCKET} exists (s3api head-bucket)" "${HEAD_BUCKET_EXIT}" "${HEAD_BUCKET_OUT}"

      VERSIONING_STATUS="$(aws_ls s3api get-bucket-versioning --bucket "${FLOW_BUCKET}" --query 'Status' --output text 2>/dev/null)"
      if [ "${VERSIONING_STATUS}" = "Enabled" ]; then
        check "${env_name}: flow-logs bucket versioning is Enabled" 0
      else
        check "${env_name}: flow-logs bucket versioning is Enabled" 1 \
          "observed Status=[${VERSIONING_STATUS}]"
      fi

      PAB_JSON="$(aws_ls s3api get-public-access-block --bucket "${FLOW_BUCKET}" --output json 2>/dev/null)"
      PAB_ALL_TRUE="$(printf '%s' "${PAB_JSON}" | jq -r '
        .PublicAccessBlockConfiguration
        | (.BlockPublicAcls == true and .BlockPublicPolicy == true and .IgnorePublicAcls == true and .RestrictPublicBuckets == true)
      ' 2>/dev/null)"
      if [ "${PAB_ALL_TRUE}" = "true" ]; then
        check "${env_name}: flow-logs bucket public access block is fully on (all four settings true)" 0
      else
        check "${env_name}: flow-logs bucket public access block is fully on (all four settings true)" 1 \
          "observed=[${PAB_JSON}]"
      fi

      LIFECYCLE_RULE_COUNT="$(aws_ls s3api get-bucket-lifecycle-configuration --bucket "${FLOW_BUCKET}" --query 'Rules' --output json 2>/dev/null | jq 'length' 2>/dev/null)"
      if [ -n "${LIFECYCLE_RULE_COUNT}" ] && [ "${LIFECYCLE_RULE_COUNT}" -ge 1 ] 2>/dev/null; then
        check "${env_name}: flow-logs bucket has a lifecycle configuration with at least one rule (${LIFECYCLE_RULE_COUNT})" 0
      else
        check "${env_name}: flow-logs bucket has a lifecycle configuration with at least one rule" 1 \
          "observed rule count=[${LIFECYCLE_RULE_COUNT:-<none>}]"
      fi
    fi

    FLOW_LOG_ID="$(printf '%s' "${OUTPUT_JSON}" | jq -r '.flow_log_id.value // empty' 2>/dev/null)"
    if [ -z "${FLOW_LOG_ID}" ]; then
      check "${env_name}: flow_log_id output is present" 1 \
        "terraform output -json has no .flow_log_id.value key"
    else
      FLOW_LOG_DESCRIBE="$(aws_ls ec2 describe-flow-logs --flow-log-ids "${FLOW_LOG_ID}" --output json)"
      FLOW_LOG_RESOURCE_ID="$(printf '%s' "${FLOW_LOG_DESCRIBE}" | jq -r '.FlowLogs[0].ResourceId // empty' 2>/dev/null)"
      FLOW_LOG_STATUS="$(printf '%s' "${FLOW_LOG_DESCRIBE}" | jq -r '.FlowLogs[0].FlowLogStatus // empty' 2>/dev/null)"

      if [ "${FLOW_LOG_RESOURCE_ID}" = "${VPC_ID}" ] && [ "${FLOW_LOG_STATUS}" = "ACTIVE" ]; then
        check "${env_name}: flow log (${FLOW_LOG_ID}) targets ${VPC_ID}, status ACTIVE" 0
      else
        check "${env_name}: flow log targets ${VPC_ID}, status ACTIVE" 1 \
          "observed ResourceId=[${FLOW_LOG_RESOURCE_ID}] FlowLogStatus=[${FLOW_LOG_STATUS}]"
      fi
    fi

    # -------------------------------------------------------------------
    # Default security group takeover + baseline shared security groups
    # (Plan 02-05, Task 3; D-28). The default-SG assertion is the strongest
    # kind this script makes: it must show EXACTLY ZERO IpPermissions and
    # EXACTLY ZERO IpPermissionsEgress entries, not merely "fewer than
    # before" -- a default security group carrying even one leftover
    # permissive rule is the exact failure mode this control exists to
    # close. allow-internal-vpc's ingress CIDR is compared for EXACT
    # equality against vpc_cidr_block's own output, not merely "some
    # ingress rule exists" -- a baseline group that allows the wrong CIDR
    # is worse than one that allows none, because it looks correct at a
    # glance.
    # -------------------------------------------------------------------
    DEFAULT_SG_ID="$(printf '%s' "${OUTPUT_JSON}" | jq -r '.default_security_group_id.value // empty' 2>/dev/null)"
    if [ -z "${DEFAULT_SG_ID}" ]; then
      check "${env_name}: default_security_group_id output is present" 1 \
        "terraform output -json has no .default_security_group_id.value key"
    else
      DEFAULT_SG_DESCRIBE="$(aws_ls ec2 describe-security-groups --group-ids "${DEFAULT_SG_ID}" --output json)"
      DEFAULT_SG_INGRESS_COUNT="$(printf '%s' "${DEFAULT_SG_DESCRIBE}" | jq -r '.SecurityGroups[0].IpPermissions | length' 2>/dev/null)"
      DEFAULT_SG_EGRESS_COUNT="$(printf '%s' "${DEFAULT_SG_DESCRIBE}" | jq -r '.SecurityGroups[0].IpPermissionsEgress | length' 2>/dev/null)"

      if [ "${DEFAULT_SG_INGRESS_COUNT}" = "0" ]; then
        check "${env_name}: default security group (${DEFAULT_SG_ID}) has zero IpPermissions (ingress)" 0
      else
        check "${env_name}: default security group has zero IpPermissions (ingress)" 1 \
          "observed count=[${DEFAULT_SG_INGRESS_COUNT:-<none>}]"
      fi

      if [ "${DEFAULT_SG_EGRESS_COUNT}" = "0" ]; then
        check "${env_name}: default security group (${DEFAULT_SG_ID}) has zero IpPermissionsEgress (egress)" 0
      else
        check "${env_name}: default security group has zero IpPermissionsEgress (egress)" 1 \
          "observed count=[${DEFAULT_SG_EGRESS_COUNT:-<none>}]"
      fi
    fi

    VPC_CIDR_BLOCK="$(printf '%s' "${OUTPUT_JSON}" | jq -r '.vpc_cidr_block.value // empty' 2>/dev/null)"
    BASELINE_SG_IDS_JSON="$(printf '%s' "${OUTPUT_JSON}" | jq -c '.baseline_security_group_ids.value // {}' 2>/dev/null)"
    BASELINE_SG_KEY_COUNT="$(printf '%s' "${BASELINE_SG_IDS_JSON}" | jq 'keys | length' 2>/dev/null)"

    if [ -z "${BASELINE_SG_KEY_COUNT}" ] || [ "${BASELINE_SG_KEY_COUNT}" -eq 0 ] 2>/dev/null; then
      check "${env_name}: baseline_security_group_ids output is present and non-empty" 1 \
        "terraform output -json has no non-empty .baseline_security_group_ids.value"
    else
      for purpose in "allow-internal-vpc" "vpc-endpoints"; do
        SG_ID="$(printf '%s' "${BASELINE_SG_IDS_JSON}" | jq -r --arg k "${purpose}" '.[$k] // empty' 2>/dev/null)"
        if [ -z "${SG_ID}" ]; then
          check "${env_name}: baseline_security_group_ids has key \"${purpose}\"" 1 \
            "no entry for \"${purpose}\" in .baseline_security_group_ids.value"
          continue
        fi

        SG_DESCRIBE="$(aws_ls ec2 describe-security-groups --group-ids "${SG_ID}" --output json)"
        SG_OBSERVED_ID="$(printf '%s' "${SG_DESCRIBE}" | jq -r '.SecurityGroups[0].GroupId // empty' 2>/dev/null)"

        if [ "${SG_OBSERVED_ID}" = "${SG_ID}" ]; then
          check "${env_name}: baseline security group \"${purpose}\" (${SG_ID}) exists" 0
        else
          check "${env_name}: baseline security group \"${purpose}\" exists" 1 \
            "expected=[${SG_ID}] observed=[${SG_OBSERVED_ID:-<none>}]"
        fi

        if [ "${purpose}" = "allow-internal-vpc" ]; then
          INGRESS_CIDR="$(printf '%s' "${SG_DESCRIBE}" | jq -r '.SecurityGroups[0].IpPermissions[0].IpRanges[0].CidrIp // empty' 2>/dev/null)"
          if [ -n "${VPC_CIDR_BLOCK}" ] && [ "${INGRESS_CIDR}" = "${VPC_CIDR_BLOCK}" ]; then
            check "${env_name}: allow-internal-vpc's ingress CIDR (${INGRESS_CIDR}) equals vpc_cidr_block exactly" 0
          else
            check "${env_name}: allow-internal-vpc's ingress CIDR equals vpc_cidr_block exactly" 1 \
              "expected=[${VPC_CIDR_BLOCK:-<none>}] observed=[${INGRESS_CIDR:-<none>}]"
          fi
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
