# variables.tf — envs/dev/data-storage (Plan 03-02, Task 1).
#
# Mirrors modules/data-storage's own variables; this env root's tfvars file
# supplies the actual dev values.

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
