# Drill: World Rebuild (D-19, D-33)

**Date:** 2026-08-04
**Run by:** `docker compose down -v` + `ansible-playbook ansible/localstack.yml` locally
(the physical LocalStack wipe/restart), then `gh workflow run rebuild-world.yml` against
the real `AuraBit/athena-infra` repository (the actual reconstruction).
**Precondition confirmed first:** `bash scripts/verify-network.sh` — 75 passed, 0 failed
across dev, stg and prod — immediately before the wipe.
**Run:** <https://github.com/AuraBit/athena-infra/actions/runs/30878817232>

**Purpose:** Prove the estate genuinely reconstructs itself from an empty LocalStack by
one dispatched workflow, and produce a first recovery-time observation for this data
class that Phase 7's disaster-recovery work compares against — not describe the
capability, observe it.

## What we did

1. Confirmed the pre-drill baseline: `scripts/verify-network.sh` green (75/75) across
   all three environments, immediately before touching LocalStack.
2. **Wiped LocalStack completely**, at `2026-08-04T04:49:08Z`:
   ```
   cd localstack && docker compose down -v
   ```
   This stopped and removed the `athena-localstack` container, the
   `localstack_localstack-data` volume, and the `localstack_default` network — not
   merely a container restart (which `PERSISTENCE=0` would have made equivalent anyway),
   but the volume itself gone, so there was no ambiguity about whether any state
   survived.
3. **Restarted LocalStack via the idempotent Ansible role**, at `2026-08-04T04:49:14Z`
   (machine start reference point):
   ```
   ansible-playbook ansible/localstack.yml
   ```
   `community.docker.docker_compose_v2` reported `changed=1` (recreated the compose
   project from nothing) and the health-endpoint wait task retried twice before the
   container reported ready — confirming this really was a cold start, not a
   fast reuse of anything cached.
4. **Confirmed the pre-rebuild state** before dispatching anything:
   - State buckets: `athena-tfstate-{dev,stg,prod}` all present again, recreated purely
     by `localstack/init/ready.d/create-state-buckets.sh` (the `ready.d` init hook) with
     zero manual intervention — this is the mechanism that makes an unattended rebuild
     possible at all.
   - VPCs: each simulated account (`111111111111`/`222222222222`/`333333333333`) showed
     **exactly one** VPC — LocalStack's own seeded default (`IsDefault: true`,
     `172.31.0.0/16`, no tags), the same behavior Plan 02-08 already documented for a
     fresh account. **Zero Terraform-managed VPCs, subnets, or NAT gateways existed** —
     confirmed by inspecting each `describe-vpcs` response directly, not inferred.
   - Terraform's own state disappeared together with the resources it described (the
     state bucket itself was gone until the `ready.d` hook recreated it empty) — the
     property that makes this coherent recovery rather than drift: Terraform is never
     left believing something exists that LocalStack no longer has.
5. **Dispatched `rebuild-world.yml`** at `2026-08-04T04:49:54Z`:
   ```
   gh workflow run rebuild-world.yml --repo AuraBit/athena-infra --ref main \
     -f target_environment=all
   ```
   Run: <https://github.com/AuraBit/athena-infra/actions/runs/30878817232>
6. **Approved the stg and prod Environment gates** as they came up — confirming the
   rebuild legs pause for the human reviewer exactly like a normal apply, not a second,
   ungated path to changing prod:
   - `select-environments` fanned to `["dev","stg","prod"]`; all three
     `rebuild-core-network` matrix legs registered a pending deployment simultaneously at
     `04:50:02Z` (dev has zero protection rules and proceeded immediately; stg/prod
     genuinely paused).
   - First approval (stg + prod together) at `04:52:22Z` — **2m20s of the elapsed time
     was waiting for a human to notice and click approve**, not machine work.
   - **`prod`'s first attempt failed almost immediately** after starting
     (`04:54:28Z`–`04:54:31Z`) with `hashicorp/setup-terraform`'s `unzip` step reporting
     `cannot find or open .../_temp/7baca07b-...` — a tool-cache download/temp-file race
     on the shared runner-pool install directory (the same underlying `athena-runner@{1,2}`
     shared-directory defect deferred-items.md item 7 already tracks; this is a fresh
     symptom of that same root cause, on a `setup-terraform` step rather than a job
     registration). Per this plan's own known-defect guidance, this was **not**
     re-diagnosed — the job was re-run (`gh run rerun --failed`), its Environment gate
     was re-approved (second approval at approximately `04:57:15Z`, another ~2m03s of
     human-wait), and the retry ran clean end to end.
   - Runner-pool serialization (also item 7: at most one instance is reliably handed
     concurrent work) meant `stg` and `prod` did not run in parallel despite both being
     approved together — `stg` started at `04:52:25Z`, `prod`'s retry did not reach
     `in_progress` until `04:58:26Z`, queued behind the runner picking up `stg` first.
     This is expected and not treated as a rebuild-workflow defect: the same pool
     limitation Plan 02-09 already documented, not anything wrong with `rebuild-world.yml`'s
     own concurrency-group scoping (each environment's group is a provably distinct string,
     `terraform-core-{dev,stg,prod}`).
7. **Confirmed the run's final conclusion**: `success`
   (`gh api .../actions/runs/30878817232 --jq .conclusion` → `"success"`) — GitHub's
   run-level conclusion reflects the latest (successful) attempt of the re-run job, and
   every job present in the final job list (`select-environments`,
   `rebuild-core-network (dev)`, `rebuild-core-network (stg)`,
   `rebuild-core-network (prod)`) shows `conclusion: success`.
8. **Confirmed recovery locally**: `bash scripts/verify-network.sh` — **75 passed, 0
   failed** across all three environments, immediately after the run completed.

## Timing (the recovery-time observation)

| Milestone | Timestamp (UTC) |
|---|---|
| LocalStack wipe started (`docker compose down -v`) | `04:49:08` |
| LocalStack restart started (`ansible-playbook`) | `04:49:14` |
| LocalStack healthy again | `04:49:16` |
| `rebuild-world.yml` dispatched | `04:49:54` |
| All three Environment gates reached "waiting" | `04:50:02` |
| First approval (stg + prod) | `04:52:22` |
| `dev` leg: start / complete | `04:50:04` / `04:51:47` |
| `stg` leg: start / complete | `04:52:25` / `04:54:12` |
| `prod` leg (1st attempt): start / failed | `04:54:28` / `04:54:31` |
| `prod` re-run's gate re-approved | `~04:57:15` |
| `prod` leg (2nd attempt): start / complete | `04:58:26` / `05:00:12` |
| Run reports `conclusion: success` | `05:00:12` |
| `scripts/verify-network.sh` confirms all three green, locally | `05:00:23` |

**Total wall clock, LocalStack-healthy to all-three-green:** `04:49:16` → `05:00:23` =
**11m07s**.

Broken into the two numbers that answer different questions about recovery, per this
drill's own instruction:

- **Machine time** (the sum of each leg's own init → plan → apply → verify duration —
  the number that matters if approvals were instant): `dev` 1m43s + `stg` 1m47s +
  `prod` (2nd, successful attempt) 1m46s = **5m16s**.
- **Approval-wait time** (elapsed time the stg/prod Environment gates spent sitting in
  `waiting`, genuinely blocked on a human clicking approve, not machine work): first
  approval 2m20s (`04:50:02`→`04:52:22`) + second approval (after the retry) ~2m03s
  (`~04:55:12`→`~04:57:15`) = **~4m23s**.
- **Residual overhead** (~1m28s): the runner-pool's item-7 serialization queue delay
  before `prod`'s retry could start (`04:57:15`→`04:58:26`, ~1m11s) plus the failed
  first attempt's own brief run (~3s) and the `gh run rerun` dispatch latency. Recorded
  honestly as a distinct bucket rather than folded into either of the two numbers above,
  since it is neither approval-wait nor genuine Terraform work — it is the runner pool's
  own pre-existing limitation surfacing again.

This is the first recorded recovery-time observation for the Core/Network stack's data
class. Phase 7's disaster-recovery work (Velero + Postgres restore drills, DR-01/DR-02)
compares its own recovery-time numbers against this one as the AWS-account-level
baseline.

## Post-drill health check

- `bash scripts/verify-network.sh`: **75 passed, 0 failed**, all three environments.
- `terraform plan -input=false -detailed-exitcode` in each of
  `envs/{dev,stg,prod}/core-network`: exit `0` — "No changes. Your infrastructure
  matches the configuration." for all three.
- The rebuild left every environment in exactly the same converged state as before the
  drill — same module version (`v1.0.0`), same variable values, same outputs (new
  resource ids, as expected for genuinely re-created infrastructure).

## Honest notes

- **The rebuild is not, on this pool, a single unattended pass on the first try.**
  `prod`'s first attempt hit a real, live tool-cache/temp-file race
  (deferred-items.md item 7's shared-runner-directory defect surfacing on a
  `hashicorp/setup-terraform` step rather than a job-registration step) and needed one
  `gh run rerun --failed` plus a second gate approval to reach green. This is recorded
  here rather than re-run silently and forgotten, because it is real evidence about this
  estate's current recovery posture: the workflow and the Environment gates behaved
  correctly throughout (no data corruption, no bypassed approval, no partial apply left
  behind), but the runner pool itself is the estate's current single point of friction
  in an otherwise-clean recovery path.
- **Environments did not rebuild in parallel**, despite `rebuild-world.yml`'s matrix
  fanning all three out at once and each carrying a provably distinct concurrency-group
  string. This is the same runner-pool limitation Plan 02-09's concurrency-queue drill
  already found and deferred (item 7: "at most one genuinely reliable concurrent job at
  a time") — not a defect in this workflow's own scoping, confirmed again by direct
  inspection of the three `terraform-core-{dev,stg,prod}` group names actually used.
- **The rebuild path did not bypass any gate.** stg and prod both genuinely paused
  (`waiting`) for the human reviewer, both times (including the retry), exactly matching
  `terraform-core-network.yml`'s own `apply` job — confirmed by the two separate
  `pending_deployments` approval calls this drill required.

## See also

- `docs/runbooks/world-rebuild.md` — the current, dispatch-ready runbook this drill is
  the worked example for.
- `.github/workflows/rebuild-world.yml` — the workflow itself.
- `.planning/phases/02-core-network-terraform-ci-verification-pattern/deferred-items.md`
  item 7 — the runner-pool shared-credentials/shared-install-directory defect this
  drill's `prod` retry is a fresh data point for.
- `docs/drills/concurrency-queue.md` — Plan 02-09's own encounter with the same
  runner-pool defect, from the concurrency-group angle rather than the tool-install
  angle.
