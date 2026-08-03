#!/usr/bin/env bash
# tf-env.sh — sourceable per-env credential helper for local Terraform runs
# against LocalStack (Plan 02-01, Task 1; CONTEXT.md D-16, D-13).
#
# Usage:  . scripts/tf-env.sh <env>      (dev|stg|prod)
#
# These "credentials" are non-secret by construction: they are LocalStack's
# account-namespacing mechanism (D-16 — LocalStack derives which simulated
# account a request lands in from the access key on the request), not an
# authorisation credential of any kind. There is nothing here to leak and
# nothing here that grants real access to anything. Do not treat this
# script, or the values it exports, as secret material.
#
# This is the local-run seam D-13 describes: in CI these same three values
# come from per-environment GitHub Environment variables (Plan 02-06)
# instead of this script, and a future real-AWS OIDC swap becomes a
# configuration change to that CI seam rather than an edit to every env
# root's backend.tf/provider.tf — both read AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY / AWS_DEFAULT_REGION from the process environment,
# never a literal in HCL.
#
# Must be SOURCED (not executed) so the exports land in the calling shell:
#   . scripts/tf-env.sh dev && cd envs/dev/core-network && terraform init

if [ -z "${1:-}" ]; then
  echo "usage: . scripts/tf-env.sh <dev|stg|prod>" >&2
  return 1 2>/dev/null || exit 1
fi

_tf_env_name="$1"

case "${_tf_env_name}" in
  dev)  _tf_env_account_id="111111111111" ;;
  stg)  _tf_env_account_id="222222222222" ;;
  prod) _tf_env_account_id="333333333333" ;;
  *)
    echo "tf-env.sh: unknown env '${_tf_env_name}' (expected dev, stg, or prod)" >&2
    unset _tf_env_name
    return 1 2>/dev/null || exit 1
    ;;
esac

export AWS_ACCESS_KEY_ID="${_tf_env_account_id}"
export AWS_SECRET_ACCESS_KEY="${_tf_env_account_id}"
export AWS_DEFAULT_REGION="us-east-1"

echo "tf-env.sh: exported AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY/AWS_DEFAULT_REGION for env '${_tf_env_name}' (simulated account ${_tf_env_account_id})"

unset _tf_env_name _tf_env_account_id
