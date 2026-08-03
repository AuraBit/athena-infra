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

Run these in order — network, then data, then compute, matching every Phase
2+ stack's own dependency order (CONTEXT.md D-15; remote-state data sources
chain the same way, IAC-05):

1. **Bring LocalStack itself back to a known-good state.**
   ```bash
   cd estate/athena-infra
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

2. **Re-create the Terraform state bucket(s).** LocalStack's S3 has no data
   left, including the bucket each Terraform stack's backend config points
   at. Every Phase 2+ stack's own `README`/`Makefile` names its exact bucket
   name and creation command once that stack lands — this step is a
   placeholder for those concrete commands until Phase 2 (Core/Network) and
   Phase 6 (Data/Storage, Application/Compute) exist. The general shape:
   ```bash
   aws --endpoint-url http://localhost:4566 s3 mb s3://<stack-state-bucket>
   ```

3. **Re-apply the Terraform stacks, in dependency order.** Network first
   (Phase 2 Core/Network — VPC, subnets, IP reservations), then data (Phase 6
   Data/Storage — RDS/ElastiCache/S3, to the extent each is `emulated` per
   `docs/localstack-service-coverage.md`), then compute (Phase 6
   Application/Compute — EKS, node pools, load balancers). Each stack's own
   directory carries the exact `terraform init && terraform apply` invocation
   once written; this runbook's job is the ordering and the "why", not the
   per-stack command, since those stacks do not exist yet as of Plan 03.
   ```bash
   # Concrete commands land here once Phase 2 / Phase 6 stacks exist:
   # (cd governance/... or terraform/network && terraform apply)
   # (cd terraform/data && terraform apply)
   # (cd terraform/compute && terraform apply)
   ```

4. **Note:** the Phase 1 governance stack (`governance/`, Plan 04) is
   deliberately **not** part of this rebuild — its state lives in a local
   file precisely because it tracks the real, persistent GitHub org, which a
   LocalStack restart never touches (CONTEXT.md D-10 vs. D-15; see
   `docs/localstack-service-coverage.md`'s "Where state lives, and why").

## Verify

```bash
bash scripts/verify-localstack.sh   # all 5 checks PASS again
aws --endpoint-url http://localhost:4566 s3 ls   # lists the re-created state bucket(s)
bash scripts/verify.sh              # full estate suite still green
```

If any Phase 2+ stack was re-applied, also re-run that stack's own
verification (its `README`/`Makefile` will name the command once it exists)
before considering the rebuild complete.

## Reasoning, for the record

State-locality is the point, not a limitation: keeping AWS-stack Terraform
state *inside* the same ephemeral account it describes means "restart"
always produces one coherent fresh world, never a world where Terraform's
memory disagrees with LocalStack's reality. Practicing this rebuild
regularly — not just reading this runbook once — is exactly the DR
discipline Phase 7's DR-01 (Velero restore drill) and DR-02 (Postgres
restore drill) formalize with real backup/restore tooling; this runbook is
the AWS-account-level version of the same muscle.
