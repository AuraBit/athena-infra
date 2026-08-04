# Runbook: World Rebuild (LocalStack Ephemerality)

**When to use this:** LocalStack (the local "AWS account", CONTEXT.md D-15)
has restarted — a host reboot, a `docker compose down`/`up`, an unplanned
container crash, or a deliberate drill — and its free-tier data is gone.

**Why this is coherent, not drift (the one-line interview answer):** Phase 2+
keeps every AWS-stack Terraform state file in LocalStack S3 itself, so a
LocalStack restart wipes state and resources **together**. Terraform never
ends up believing a bucket/instance/cluster exists when it doesn't — the
alternative (state stored anywhere durable) would leave exactly that kind of
drift after every restart. This is recurring DR practice this project
practices on purpose, not a failure mode to be avoided — Phase 7's
DR-01/DR-02 (Velero + Postgres backup/restore drills) build directly on the
same muscle memory this runbook exercises.

## Symptom

- `docker ps` no longer shows `athena-localstack` running, or it restarted
  recently (`docker inspect athena-localstack --format '{{.State.StartedAt}}'`
  jumped forward).
- `bash scripts/verify-localstack.sh` fails on the S3 round-trip check, or
  every `aws --endpoint-url http://localhost:4566 ...` call returns
  `NoSuchBucket` / empty results for things that used to exist.
- `aws --endpoint-url http://localhost:4566 s3 ls` returns nothing (or is
  missing the state bucket any Phase 2+ Terraform stack expects).
- The health endpoint (`curl -sf http://localhost:4566/_localstack/health`)
  answers fine — LocalStack itself is healthy, its **data** is gone. This is
  the expected, coherent state this runbook restores from, not a bug.

## Confirm

Before rebuilding anything, confirm the symptom is really "LocalStack lost
its data," not something else (a stopped systemd unit, a missing token, a
network problem — those have different fixes):

```bash
systemctl is-active localstack               # expect: active
curl -sf http://localhost:4566/_localstack/health | jq .services | head   # expect: a populated services map
aws --endpoint-url http://localhost:4566 s3 ls   # expect: empty, or missing buckets you know existed
```

If `systemctl is-active localstack` is not `active`, start with Rebuild step
1 below (`ansible-playbook ansible/localstack.yml` also fixes a stopped
unit). If the health endpoint itself fails to answer, check
`estate/athena-infra/localstack/.localstack.env` still has a non-empty
`LOCALSTACK_AUTH_TOKEN` — an expired or revoked token produces this same
symptom (this plan's flagged assumption: an expired-mid-session token is not
detected until the next verification run).

## Rebuild

As of Plan 02-10, this is a single dispatched workflow, not a sequence of
manual per-stack commands. `.github/workflows/rebuild-world.yml`
(`workflow_dispatch`-only, never `push`/`pull_request`) re-applies every
environment of every stack in dependency order — today that is Core/Network
across dev/stg/prod; Phase 6 extends the same file with one new
`rebuild-<stack>` job per additional stack (Data/Storage, then
Application/Compute), each depending on the job for the stack before it.

1. **Bring LocalStack itself back to a known-good state.** If it merely
   restarted (host reboot, `docker compose down`), this step alone is
   enough — LocalStack's own `ready.d` init hook
   (`localstack/init/ready.d/create-state-buckets.sh`, D-18) recreates
   `athena-tfstate-{dev,stg,prod}` by itself the moment the container
   reports healthy, with zero manual bucket-creation step. If you are
   deliberately drilling (not just recovering from a real restart), wipe the
   data volume explicitly first so there is no ambiguity about what
   survived:
   ```bash
   cd estate/athena-infra
   cd localstack && docker compose down -v && cd ..
   ansible-playbook ansible/localstack.yml
   # equivalently, from the planning-repo root:
   #   ansible-playbook estate/athena-infra/ansible/localstack.yml
   #   (run from inside estate/athena-infra/ itself; playbook_dir resolves
   #   the localstack/ directory relative to that, per the role's own
   #   "Resolve the localstack/ directory this role manages" task)
   ```
   This is idempotent (Plan 03, Task 1's `community.docker`-based role) —
   safe to run whether the systemd unit was stopped, the compose project was
   down, or LocalStack was already fine. It re-asserts the systemd unit,
   brings the compose project up, and waits for the health endpoint.

2. **Dispatch the rebuild workflow.**
   ```bash
   gh workflow run rebuild-world.yml --repo AuraBit/athena-infra --ref main \
     -f target_environment=all   # or: dev | stg | prod, for a partial rebuild
   ```
   `target_environment=all` fans out to dev, stg and prod in parallel
   (matrix); each leg is a straight copy of `terraform-core-network.yml`'s
   own `apply` job — same self-hosted runner label set, same
   `terraform-core-${env}` concurrency group (a rebuild contends with a
   normal apply for that environment rather than bypassing it), same
   `environment: ${env}` binding (stg/prod still pause for the human
   reviewer — this is not a second, ungated path to changing prod), and the
   same `scripts/verify-network.sh ${env}` step as the leg's final step.

3. **Approve the stg and prod gates when they pause**, the same way you
   would for any normal merge-triggered apply:
   ```bash
   gh api repos/AuraBit/athena-infra/actions/runs/<run-id>/pending_deployments
   gh api --method POST repos/AuraBit/athena-infra/actions/runs/<run-id>/pending_deployments \
     -f state=approved -f comment="world rebuild" -F "environment_ids[]=<id>"
   ```
   Record how much of the run's elapsed time was this approval wait versus
   genuine Terraform work — the two numbers answer different recovery-time
   questions; see `docs/drills/world-rebuild.md` for a worked example of
   this split.

4. **Note:** the Phase 1 governance stack (`governance/`, Plan 04) is
   deliberately **not** part of this rebuild, and never will be — its state
   lives in a local file precisely because it tracks the real, persistent
   GitHub org, which a LocalStack restart never touches (CONTEXT.md D-10 vs.
   D-15; see `docs/localstack-service-coverage.md`'s "Where state lives, and
   why").

## What a human must check afterwards that the workflow cannot check for itself

`rebuild-world.yml`'s own `verify-network.sh` step proves each environment's
resources are real and match Terraform's outputs — it does **not** prove the
rebuild produced infrastructure a human actually wanted. After a rebuild
completes green, a human should still:

- **Read the job summaries** (`gh run view <run-id>` or the Actions UI) for
  each leg's fresh plan output — a rebuild that reports `success` after
  creating something genuinely different from before (a module version bump
  that landed between the last known-good state and now, a tfvars change
  nobody reviewed) is not something any automated check here catches; only a
  human reading the plan diff catches an unwanted change riding along with a
  wanted recovery.
- **Confirm no stack was silently skipped.** `target_environment` defaults
  to `all`, but a partial rebuild (`dev`/`stg`/`prod` alone) is a valid,
  intentional input — a human should confirm the dispatch used the input
  they meant to use, since the workflow has no way to know which one was
  intended.
- **Re-run any drill or manual verification a specific environment's own
  documentation calls for** beyond `verify-network.sh` (e.g.
  `scripts/verify-tfstate-locking.sh` if a lock-related incident preceded
  this rebuild) — this workflow's own verify step is scoped to IAC-04
  (resources are real), not every other property a given recovery might
  need re-confirmed.

## Verify

```bash
bash scripts/verify-localstack.sh   # all 5 checks PASS again
aws --endpoint-url http://localhost:4566 s3 ls   # lists the re-created state bucket(s)
bash scripts/verify-network.sh      # all three environments green (IAC-04)
bash scripts/verify.sh              # full estate suite still green
```

See `docs/drills/world-rebuild.md` for the worked example: a real dispatch,
a real approval-wait/machine-time split, and a real transient failure
(a runner-pool tool-cache race, deferred-items.md item 7) encountered and
recovered from live.

## Reasoning, for the record

State-locality is the point, not a limitation: keeping AWS-stack Terraform
state *inside* the same ephemeral account it describes means "restart"
always produces one coherent fresh world, never a world where Terraform's
memory disagrees with LocalStack's reality. Practicing this rebuild
regularly — not just reading this runbook once — is exactly the DR
discipline Phase 7's DR-01 (Velero restore drill) and DR-02 (Postgres
restore drill) formalize with real backup/restore tooling; this runbook is
the AWS-account-level version of the same muscle.
