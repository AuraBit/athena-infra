# Drills

A **drill** in this estate is a record of what happened when a failure scenario or a
correctness claim was actually caused and observed — not a description of what should
happen. A **runbook** (`docs/runbooks/`) says what to do when a real incident occurs; a
drill proves the runbook's procedure genuinely works, or proves a mechanism (a
concurrency group, a state lock, a verification script) genuinely does what it claims,
by triggering it for real and recording the observed result, including when the result
is honestly a partial pass or a "not reproduced." Phase 7's disaster-recovery drills
extend this same directory and the same evidentiary standard.

## Phase 2 drills

| Drill | Date | Outcome |
|---|---|---|
| [Concurrency queue](concurrency-queue.md) | 2026-08-04 | Scenarios 1 (same-environment queuing) and 3 (PR plan not blocked by an in-flight apply) both **PASS**, live, with real Actions run URLs. Scenario 2 (two environments applying concurrently) is recorded as **not reproduced** after six real attempts — root-caused to the runner pool's shared `.runner`/`.credentials` files (deferred-items.md item 7), not to a concurrency-group defect; the group's per-environment scoping remains correct by direct source inspection and by every dev/stg/prod apply across Plans 02-04–02-08 never once colliding. |
| [Stale-lock recovery](stale-lock-recovery.md) | 2026-08-04 | A real stuck lock was caused, diagnosed from Terraform's own error output, and recovered via the documented force-unlock procedure — confirmed by a clean `terraform plan` (no drift) and `verify-tfstate-locking.sh` (3/3) afterward. |
| [World rebuild](world-rebuild.md) | 2026-08-04 | `rebuild-world.yml`, dispatched against a genuinely wiped LocalStack, reconstructed all three environments end to end in 5m16s of machine time (~4m23s of that waiting on human approval) — proving the world-rebuild runbook is a real, repeatable recovery path, not aspirational documentation. |
| [Fake-success verification](fake-success-verification.md) | 2026-08-04 | A resource deleted behind Terraform's back was caught live in CI, twice, by `verify-network.sh` (13/13 passed on the proof run) — and the drill's first attempt found a genuine coverage gap (`public_route_table_id`'s own default route was not asserted, so a deleted route briefly reported a false 25/25 green) which was closed before the second, clean proof run. |
