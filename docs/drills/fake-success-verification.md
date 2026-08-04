# Drill: Fake-Success Verification (IAC-04, D-33)

**Date:** 2026-08-04
**Run by:** `bash scripts/drills/fake-success-drill.sh` (local + real GitHub Actions
dispatches against `AuraBit/athena-infra`), target environment `dev`.
**Precondition confirmed first:** `bash scripts/verify-network.sh` — 75 passed, 0
failed across dev, stg and prod — immediately before this drill began.
**Result:** `[fake-success-drill] 13 passed, 0 failed, 13 total.`

**Purpose:** IAC-04 exists because LocalStack can report an apply as successful while
the resource it claims to have created is not really there — already live-proven for
four license-gated services (`docs/localstack-service-coverage.md`:
rds/elasticache/cloudfront/eks). Those services are out of scope on this account, so
this drill induces the equivalent divergence directly: delete a real resource through
the AWS CLI, bypassing Terraform entirely, and require `verify-network.sh` to notice —
the only evidence that the guard actually works, as opposed to being trusted to.

## Why the CI proof needed a specific mechanism, not just "delete and dispatch"

Building this drill surfaced a fact worth recording before the results: **Terraform's
own `plan` genuinely refreshes and detects a directly-deleted EC2/S3 resource.** An
empirical check (deleting a NAT gateway directly, then running `terraform plan`)
showed a real diff (`Plan: 1 to add, 3 to change`) — meaning an ordinary CI apply run
against a diverged environment just *heals* the divergence, healthily and correctly.
That is good behavior, but it means the CI proof this drill needs — "apply step green,
job red at verify" **in the same run** — cannot come from simply deleting a resource
and then dispatching a normal apply; the fresh plan would recreate it and verify would
then correctly see it restored, never proving the failure mode at all.

The mechanism this drill actually uses: dispatch the workflow while the environment is
still fully converged (so `terraform plan`'s saved plan file reflects "no changes"),
then delete the target resource **the instant that run's own `terraform apply` step
reports success**. `terraform apply <planfile>` applies exactly the saved plan graph —
it does not re-verify untouched resources — so it reports genuine success even though
the resource is gone by the time `verify-network.sh` (which makes its own independent
`describe`/`head-bucket` calls, every time, never trusting the plan) runs a few seconds
later in the same job. This is not staged or contrived: it is a real, live-provable
instance of "an operation reported success while the resource wasn't there," using a
LocalStack-account-only mechanism in place of the license-gated services this project
cannot reach directly.

## What we did

### Phase 1 — Variant 1: a resource `verify-network.sh` already asserts on

1. Recorded `flow_logs_bucket_name=athena-flowlogs-dev` from `terraform output -json`.
2. Deleted it directly: `aws --endpoint-url http://localhost:4566 s3 rb
   s3://athena-flowlogs-dev --force`, at `05:28:58Z`.
3. `bash scripts/verify-network.sh dev` — exit `1`, verbatim:
   ```
   FAIL  dev: flow-logs bucket athena-flowlogs-dev exists (s3api head-bucket)
   ```
   (plus three further FAILs for the bucket's versioning, public-access-block, and
   lifecycle-configuration sub-checks — every check that reads the now-gone bucket
   failed, none silently passed.)
4. Restored: `terraform apply -input=false -auto-approve`. Confirmed
   `verify-network.sh dev` green again and `terraform plan -detailed-exitcode` exit `0`.

### Phase 2 — Variant 2: the coverage gap this drill found

The verifier's own assertion set was audited against every output
`modules/core-network/outputs.tf` declares. `public_route_table_id` (the public
subnets' shared route table, carrying the `0.0.0.0/0 → internet gateway` route) had
existed as an output since Plan 02-03 but had **no independent assertion of its own** in
`verify-network.sh` — every other route table (`private_app_route_table_ids`,
`private_data_route_table_ids`) was checked; this one was not.

**Proven live, before any fix:**
```
$ aws --endpoint-url http://localhost:4566 ec2 delete-route \
    --route-table-id rtb-96a8aad422d524244 --destination-cidr-block 0.0.0.0/0

$ bash scripts/verify-network.sh dev
...
[verify-network] 25 passed, 0 failed, 25 total.
```
**A genuinely diverged environment — the public route table's only path to the
internet gone — reported a fully vacuous green.** This is exactly the fake-success
condition IAC-04 exists to catch, just not yet caught for this one resource. Recorded
as a real finding, not buried: the drill's whole purpose is finding gaps like this one,
and finding one is a better outcome than not finding one.

**The fix** (`scripts/verify-network.sh`, same shape as the existing
`private_app_route_table_ids` check): assert `public_route_table_id`'s
`describe-route-tables` response contains a `0.0.0.0/0` route whose `GatewayId` equals
`internet_gateway_id`.

**Proven live, after the fix, same still-diverged environment:**
```
$ bash scripts/verify-network.sh dev
...
FAIL  dev: public_route_table_id has a 0.0.0.0/0 route to internet_gateway_id
      observed: expected gateway=[igw-39b4cfc3a25f90781] observed gateway=[<none>]
...
[verify-network] 21 passed, 4 failed, 25 total.
```
The gap is closed — `scripts/drills/fake-success-drill.sh`'s Phase 2 now runs this
same deletion as a standing regression check on every future invocation, asserting the
verifier catches it.

Restored: `terraform apply -input=false -auto-approve`. Confirmed
`verify-network.sh dev` green again (**26 checks now**, one more than before the fix)
and `terraform plan -detailed-exitcode` exit `0`.

### Phase 3 — the CI proof: apply green, job red, in the same real run

Run: <https://github.com/AuraBit/athena-infra/actions/runs/30880950754>

1. Dispatched `terraform-core-network.yml`'s `workflow_dispatch` path
   (`drill_env=dev`, `drill_hold_seconds=0`, Plan 02-09's existing drill input) at
   `05:31:32Z`, against a fully converged dev (no divergence yet).
2. Polled the run's `apply (dev)` job for its `terraform apply` step's own
   `conclusion` via `gh api .../jobs`. It reported `success` at `05:33:21Z`.
3. **Immediately** (`05:33:22Z`, one second later) deleted
   `s3://athena-flowlogs-dev` directly, the same way as Phase 1 — the saved plan this
   run already applied never touched the bucket (nothing had changed at plan time), so
   this deletion happened entirely outside anything Terraform observed in this run.
4. Waited for the job to complete. Final state, read directly from the Actions API:

   | | conclusion |
   |---|---|
   | `terraform apply` step | **`success`** |
   | `verify-network.sh (IAC-04 …)` step | **`failure`** |
   | `apply (dev)` job (overall) | **`failure`** |
   | Run (overall) | `failure` |

5. Verbatim FAIL output from the job's own log
   (`gh run view --job <id> --log-failed`), stripped of ANSI color codes for
   readability here — the CI log itself carries the same colored `PASS`/`FAIL`
   markers `verify-network.sh` prints locally:
   ```
   2026-08-04T05:33:31.9282852Z FAIL  dev: flow-logs bucket athena-flowlogs-dev exists (s3api head-bucket)
   2026-08-04T05:33:32.4808191Z FAIL  dev: flow-logs bucket versioning is Enabled
   2026-08-04T05:33:33.0625152Z FAIL  dev: flow-logs bucket public access block is fully on (all four settings true)
   2026-08-04T05:33:33.6222716Z FAIL  dev: flow-logs bucket has a lifecycle configuration with at least one rule
   2026-08-04T05:33:36.1329892Z [verify-network] 21 passed, 4 failed, 25 total.
   ```
6. Restored: `terraform apply -input=false -auto-approve`. Confirmed
   `verify-network.sh dev` green again and `terraform plan -detailed-exitcode` exit `0`.

**This is the clearest possible artifact for IAC-04:** in one real, unmodified CI run,
the `terraform apply` step is unambiguously green (Terraform did exactly what its saved
plan said, and nothing in that plan was wrong), while the job as a whole is red, because
`verify-network.sh`'s independent describe call — not the apply step's own exit code —
is what caught the resource actually being gone.

## Post-drill health check

- `bash scripts/verify-network.sh`: **78 passed, 0 failed**, all three environments
  (25 → 26 checks per environment after Phase 2's fix, the new `public_route_table_id`
  assertion).
- `terraform plan -input=false -detailed-exitcode` in each of
  `envs/{dev,stg,prod}/core-network`: exit `0` — no drift, all three.
- `scripts/drills/fake-success-drill.sh` itself: `13 passed, 0 failed, 13 total` —
  every phase's own assertions, including the CI proof, passed on this run.

## Honest notes

- **The coverage gap (Phase 2) was a genuine, live discovery**, not manufactured for
  this drill's narrative — `public_route_table_id` had simply never had its own
  assertion since the output was added in Plan 02-03, and nothing in this phase's prior
  verification work happened to exercise it. Finding it here, rather than leaving it
  unfound, is this drill doing exactly what it exists to do.
- **The CI proof's mechanism (delete after the apply step, before verify) is the
  correct, non-staged way to reproduce "apply green, resource gone" without the
  license-gated services this account cannot reach** — it is not a workaround or a
  shortcut. `terraform apply <planfile>` genuinely does not re-examine resources with
  no planned action, so the apply step's `success` conclusion is completely honest
  about what Terraform itself did; the divergence lives entirely outside anything that
  run's Terraform invocation observed.
- **This drill did not encounter Plan 02-09's deferred runner-pool defect
  (deferred-items.md item 7)** — dev carries no Environment protection rules, so this
  drill's single dispatched run needed no approval gate and no cross-environment
  concurrency, the specific conditions that defect affects.

## See also

- `scripts/drills/fake-success-drill.sh` — the repeatable driver.
- `scripts/verify-network.sh` — the verifier itself, now carrying the
  `public_route_table_id` assertion this drill's Phase 2 added.
- `docs/localstack-service-coverage.md` — the four license-gated services where this
  exact failure mode (`available` per the health endpoint, real calls fail) was first
  live-proven, which this drill stands in for on this account.
- `docs/drills/world-rebuild.md` — Plan 02-10's other drill, the same phase's
  disaster-recovery half.
