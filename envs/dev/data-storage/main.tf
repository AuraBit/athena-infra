# main.tf — envs/dev/data-storage (Plan 03-02, Task 1; CONTEXT.md D-04,
# D-07).
#
# Small, explicit env root, same shape as envs/dev/core-network/main.tf. The
# module source is a git-tag ref against this SAME repo (D-04) — never a
# relative path, for the identical audit-trail reason core-network's own
# main.tf explains: a relative source always resolves to whatever is on
# disk at apply time, with no record of which module version actually
# applied.
module "data_storage" {
  source = "git::https://github.com/AuraBit/athena-infra.git//modules/data-storage?ref=modules/data-storage/v0.1.1"

  name_prefix       = var.name_prefix
  environment       = var.environment
  media_bucket_name = var.media_bucket_name
}
