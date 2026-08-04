# Drill: Concurrency-Queue (IAC-03, D-33)

**Date:** 2026-08-04
**Run by:** `scripts/drills/concurrency-queue-drill.sh` (repeatable — every invocation
dispatches fresh, real `terraform-core-network.yml` runs against `AuraBit/athena-infra`)
**Purpose:** Prove, by causing and watching it (not describing it), that two applies
targeting the same environment queue rather than race (success criterion 2), that the
concurrency group is scoped per stack+environment rather than globally (D-06), and that
a PR plan for an environment runs while an apply for that same environment is in flight
(Pitfall 6 — the group must live inside the `apply` job, not at workflow level).

RESEARCH.md's Open Question 2 is why this drill exists as a script rather than "push
twice and eyeball the Actions tab": GitHub's own scheduling latency means two quick
pushes often just execute sequentially anyway, which looks identical to queuing and
proves nothing. The driver forces the first apply to hold its concurrency group for a
known window (the drill-only `drill_hold_seconds` `workflow_dispatch` input added to
`terraform-core-network.yml` for exactly this purpose) so the second run's queued state
is unambiguous.

This record reflects the cleanest complete real run for scenarios 1 and 3 (run
`2026-08-04T03:41:51Z`–`03:57:39Z`), and the most rigorous real attempt for scenario 2
(run `2026-08-04T04:10:11Z`–`04:26:51Z`, using the strengthened dual-sample overlap
check — see "Scenario 2" below for why an earlier, weaker check briefly produced a false
PASS). All run IDs, PR numbers, and timestamps below are real and independently
verifiable via `gh run view <id> --repo AuraBit/athena-infra`.

## Scenario 1 — same environment (dev) twice: must queue

**Command:** `dispatch_run dev 130` (RUN1), then `dispatch_run dev 0` (RUN2) once RUN1's
`apply (dev)` job is observed `in_progress`.

| Event | Time (UTC) | Run |
|---|---|---|
| RUN1 dispatched (dev, hold=130s) | 2026-08-04T03:41:57Z | [30875491003](https://github.com/AuraBit/athena-infra/actions/runs/30875491003) |
| RUN1 `apply (dev)` reaches `in_progress` | 2026-08-04T03:43:26Z | |
| RUN2 dispatched (dev, hold=0s) | 2026-08-04T03:43:30Z | [30875568486](https://github.com/AuraBit/athena-infra/actions/runs/30875568486) |
| RUN2 `apply (dev)` observed `queued`, RUN1 still in flight | 2026-08-04T03:46:27Z | |
| RUN1 `apply (dev)` completes | 2026-08-04T03:46:28Z, conclusion `success` | |
| RUN2 `apply (dev)` reaches `in_progress` (strictly after RUN1's completion) | 2026-08-04T03:47:29Z | |
| RUN2 `apply (dev)` completes | 2026-08-04T03:48:19Z, conclusion `success` | |

**Result: PASS.** RUN2 sat `queued` while RUN1 held the `terraform-core-dev`
concurrency group, and RUN2's own start (03:47:29Z) is strictly later than RUN1's
completion (03:46:28Z) — the load-bearing, unambiguous proof that no two applies for one
environment ever ran at the same time, independent of exactly which status label GitHub
reported at any single poll (see the honest note below on `queued` vs `pending`).

**One vocabulary note, recorded for anyone re-running this drill:** across different
invocations, GitHub's job-status API returned `queued` in one run and `pending` in
another for the identical "not yet started, blocked" state — both are treated as
equivalent evidence of queuing by the driver; only `in_progress`/`completed` mean the job
actually started.

## Scenario 2 — two different environments (dev + stg) at the same time: must run concurrently

**Command:** `dispatch_run dev 130` (RUN3), wait for `in_progress`, then
`dispatch_run stg 20` (RUN4), approving stg's gated Environment as soon as its pending
deployment appears (the same human-reviewer identity — `YahiaEng`, `governance/environments.tf`'s
`infra_stg` — Plan 02-08's gated promotion already used live).

| Event | Time (UTC) | Run |
|---|---|---|
| RUN3 dispatched (dev, hold=130s) | 2026-08-04T04:15:42Z | [30877151009](https://github.com/AuraBit/athena-infra/actions/runs/30877151009) |
| RUN3 `apply (dev)` reaches `in_progress` | 2026-08-04T04:17:06Z | |
| RUN4 dispatched (stg, hold=20s) | 2026-08-04T04:17:10Z | [30877222571](https://github.com/AuraBit/athena-infra/actions/runs/30877222571) |
| RUN4 pending deployment (stg) approved | 2026-08-04T04:18:34Z | |
| RUN4 `apply (stg)` reaches `in_progress` | 2026-08-04T04:20:15Z | |
| Dual-sample poll (both jobs' status read together) | 2026-08-04T04:20:16Z: RUN3=`completed`, RUN4=`in_progress` | |
| RUN3 `apply (dev)` completes | 2026-08-04T04:20:17Z, conclusion `success` | |
| RUN4 `apply (stg)` completes | 2026-08-04T04:21:25Z, conclusion `success` | |

**Result: NOT REPRODUCED — recorded honestly, with what was tried.**

RUN3 and RUN4 both completed successfully, and their windows technically abut
(`[04:17:06Z .. 04:20:17Z]` and `[04:20:15Z .. 04:21:25Z]`) — but the dual-sample check
(polling both jobs' status together, requiring at least two consecutive ticks where both
simultaneously read `in_progress`) scored **0 concurrent ticks**. RUN4 started 2 seconds
*after* RUN3 finished, not alongside it. This is a genuine, real observation, not a
scripting mistake presented as a pass — an earlier draft of this drill's check compared
only the two jobs' separately-polled start/end timestamps and, on a different attempt,
that weaker comparison was satisfied by an identical back-to-back pattern (RUN4 started
1 second before the *previous* attempt's RUN3 ended), producing a false PASS. The
dual-sample check exists specifically because that class of false positive is worse than
an honest failure — see `scripts/drills/concurrency-queue-drill.sh`'s own comment on
this.

**What was tried, and the root cause found:** this scenario was attempted six times
total across this drilling session (three full three-scenario runs, one targeted
single-scenario retry, plus two manual runner restarts in between) — every attempt
showed the same signature: all dispatched jobs (dev apply, stg apply, and later the
plan-during-apply scenario's plan job) landed on a *single* self-hosted runner instance,
one after another, never on both of the pool's two instances at once.
`journalctl -u athena-runner@1 -u athena-runner@2` traced this to a real, pre-existing
infrastructure defect: the two ephemeral runner instances (`athena-runner@1`,
`athena-runner@2`) share one install directory's `.runner`/`.credentials` files (a
known, documented tradeoff from Plan 02-02 — see STATE.md's decision log), and whichever
instance most recently re-registered "wins" that shared file, breaking the other
instance's live listener session (`Runner connect error: Registration <uuid> was not
found`, `An error occurred: Credentials not stored. Must reconfigure.`, and — on a clean
simultaneous restart of both instances — `Runner connect error: The signature is not
valid.`, all captured live during this session). Full evidence, timestamps, and the
recommended fix are recorded in
`.planning/phases/02-core-network-terraform-ci-verification-pattern/deferred-items.md`
item 7 and in `STATE.md`'s blockers.

**What this does and does not mean for IAC-03/D-33:** the *workflow-level* claim this
scenario exists to support — that `concurrency: group: terraform-core-${{ matrix.env }}`
produces a genuinely independent concurrency group per environment, not a single global
one — is true by direct inspection of `terraform-core-network.yml`'s source (the group
name interpolates `matrix.env`, so `terraform-core-dev` and `terraform-core-stg` are
provably different strings the moment two different `matrix.env` values are substituted
in), and is indirectly corroborated by every dev/stg/prod apply across Plans 02-04
through 02-08 never once colliding or blocking on each other's state. What this drill
could **not** do is *watch* two environments' applies genuinely overlap in wall-clock
time, because the runner pool this estate currently runs cannot sustain two genuinely
simultaneous self-hosted jobs regardless of which two environments or jobs they are —
that is a runner-pool capacity/architecture defect, not a concurrency-group defect, and
conflating the two would be exactly the kind of false confidence this drill exists to
prevent. Re-running this scenario once the runner pool's shared-credentials issue is
fixed (deferred-items.md item 7) is the correct way to close this out with genuine live
evidence.

## Scenario 3 — PR plan (dev) while an apply (dev) is in flight: plan must not queue

**Command:** `dispatch_run dev 25` (RUN5), wait for `in_progress`, then open a
comment-only touch to `envs/dev/core-network/backend.tf` on a new branch as a real pull
request (triggers `plan (dev)` via `detect-changes`'s path filter), then close the PR
without merging once evidence is captured.

| Event | Time (UTC) | Run |
|---|---|---|
| RUN5 dispatched (dev, hold=25s) | 2026-08-04T03:54:16Z | [30876065871](https://github.com/AuraBit/athena-infra/actions/runs/30876065871) |
| RUN5 `apply (dev)` reaches `in_progress` | 2026-08-04T03:55:38Z | |
| Drill PR opened | 2026-08-04T03:55:41Z | [PR #38](https://github.com/AuraBit/athena-infra/pull/38) |
| PR's workflow run created | | [30876135915](https://github.com/AuraBit/athena-infra/actions/runs/30876135915) |
| `plan (dev)` reaches `in_progress` (RUN5's apply still in flight) | 2026-08-04T03:57:03Z | |
| `plan (dev)` completes | 2026-08-04T03:57:36Z, conclusion `success` | |
| Drill PR #38 closed without merging, branch deleted | 2026-08-04T03:57:38Z | |
| RUN5 `apply (dev)` completes | 2026-08-04T03:57:39Z, conclusion `success` | |

**Corroborating run** (independent, earlier attempt during this same session, identical
qualitative result): RUN5 dispatched at `2026-08-04T03:36:34Z` (dev, hold=25s, run
[30875238491](https://github.com/AuraBit/athena-infra/actions/runs/30875238491));
`apply (dev)` `in_progress` at `03:38:01Z`; drill PR
[#37](https://github.com/AuraBit/athena-infra/pull/37) opened `03:38:05Z`; its
workflow run [30875312775](https://github.com/AuraBit/athena-infra/actions/runs/30875312775)'s
`plan (dev)` reached `in_progress` at `03:39:25Z` and completed at `03:39:58Z`
(conclusion `success`) — again promptly, never queued, while RUN5's apply was still in
flight (it completed at `03:40:01Z`, after `plan (dev)` had already finished).

**Result: PASS (both runs).** In both independent attempts, `plan (dev)` reached
`in_progress` within roughly a minute of the PR opening — never `queued` behind
`apply (dev)`'s concurrency group — proving the `concurrency:` block genuinely lives
inside the `apply` job only, not at workflow level (the exact trap
`terraform-core-network.yml`'s own comment on the `apply` job warns about, Pitfall 6).
`plan (dev)`'s own Terraform step completed successfully both times (a real
`terraform plan` against dev, no diff) rather than hitting state-lock contention with
the concurrently-running `apply (dev)` — a genuine lock-contention error (as opposed to
a queued/skipped job) would have been an equally acceptable, honestly-reportable outcome
here, since it too is proof the job ran, not proof it was blocked; it simply did not
happen to occur in either of these two runs.

## The honest asterisk: arrival order is not an apply-order guarantee

GitHub's concurrency groups hold **at most one pending run per group** — a third arrival
supersedes the pending one rather than joining a queue behind it. This drill's own
design (one holder + one pending run at a time, never three) proves that two applies for
one environment never run at the same time (scenario 1) — it does not, and cannot, prove
that the *order* two runs arrive in is the order they apply. In every scenario-1 run
captured here, arrival order and apply order happened to coincide (RUN1 arrived first,
applied first; RUN2 arrived second, applied second) — but that is what was *observed* in
this estate's runs, not a guarantee GitHub's own documented semantics make. The
correctness guarantee that actually matters — no two applies for one environment writing
state at the same time — is the state lock (`use_lockfile = true`,
`scripts/verify-tfstate-locking.sh`, Plan 02-01), not the concurrency group; the
concurrency group is what stops runs from colliding on it in the first place. Both
matter; only one is an ordering promise.
