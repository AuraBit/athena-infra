# locals.tf — modules/data-storage v0.1.0 (Plan 03-02, Task 1).
#
# media_bucket_name: var.media_bucket_name overridden if set (Phase 6 /
# real-AWS global-uniqueness escape hatch), else the estate's own
# athena-media-<environment> convention (mirrors athena-tfstate-<env> /
# athena-flowlogs-<env>).

locals {
  media_bucket_name = coalesce(var.media_bucket_name, "${var.name_prefix}-media-${var.environment}")
}
