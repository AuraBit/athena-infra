# variables.tf — envs/dev/data-storage (Plan 03-02, Task 1).
#
# Mirrors modules/data-storage's own variables; this env root's tfvars file
# supplies the actual dev values.
#
# Comment-only touch (Plan 03-02, Task 3): this envs/dev/data-storage-only
# change is the live-verification PR for terraform-data-storage.yml --
# detect-changes should report dev=true, the plan matrix should fan out to
# exactly one leg (dev), the sticky comment should post under header
# data-storage-dev, and gate should aggregate plan's (and, after merge,
# apply's) result under the same "gate" required check
# terraform-core-network.yml's own gate already satisfies.

variable "name_prefix" {
  description = "Short project/estate prefix used in resource Name tags."
  type        = string
}

variable "environment" {
  description = "Environment this stack applies to."
  type        = string
}

variable "media_bucket_name" {
  description = "Override for the media bucket name; left null to take the module's own athena-media-<environment> default."
  type        = string
  default     = null
}
