# variables.tf — modules/data-storage v0.1.0 (Plan 03-02, Task 1; CONTEXT.md
# D-07).
#
# Deliberately three inputs only, mirroring modules/core-network's own
# variables.tf shape (name_prefix + environment + one resource-specific
# knob) — this module's whole point is proving the same module -> tag ->
# env-root -> apply -> awslocal-verify tracer path Plan 02-01 proved for
# core-network, applied to a second lifecycle stack, at minimum size.

variable "name_prefix" {
  description = "Short project/estate prefix used in resource Name tags (e.g. \"athena\")."
  type        = string
}

variable "environment" {
  description = "Environment this stack belongs to (dev, stg, or prod) — also carried as the Environment tag via default_tags."
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prod"], var.environment)
    error_message = "environment must be one of: dev, stg, prod."
  }
}

# Flagged assumption (03-02-PLAN.md): bucket naming is Claude's discretion
# per CONTEXT.md. Defaulting to null and computing "athena-media-<env>" in
# locals.tf (mirroring the athena-tfstate-<env> / athena-flowlogs-<env>
# convention already in the estate) — but exposed as a real, overridable
# input, not a hardcoded literal, so a future real-AWS deployment (which
# needs a globally-unique bucket name) or Phase 6's expansion of this stack
# can pass a different value without a module change.
variable "media_bucket_name" {
  description = "Name of the media S3 bucket. Defaults to \"athena-media-<environment>\" (mirrors athena-tfstate-<env>/athena-flowlogs-<env>) if left null."
  type        = string
  default     = null
}
