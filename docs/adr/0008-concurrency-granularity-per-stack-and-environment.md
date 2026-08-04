# 0008. Concurrency Granularity: Per Stack and Environment, Scoped Inside the Apply Job

* Status: accepted
* Date: 2026-08-04
* Deciders: Yahia Tarek (YahiaEng)
* Tier: short-form

## Context

IAC-03's own literal wording named a per-environment concurrency group
(`terraform-prod`, `cancel-in-progress: false`), and that wording undersells
what the group boundary actually needs to be. This repository's state files
are per **stack** per **environment** — `envs/dev/core-network` has its own
state, and Phase 6 adds sibling stacks (`data-storage`,
`application-compute`) each with their own per-environment state alongside
it. A lock boundary that is coarser than the state boundary it protects
produces false contention: a `data-storage` apply in dev and a
`core-network` apply in dev would queue behind each other under a purely
per-environment group, despite touching entirely disjoint state files and
having no actual conflict to serialize against.

A second, independent question is *where* in the workflow the group is
declared. `terraform-core-network.yml`'s `apply` job carries its own
inline comment warning about the trap: a workflow-level `concurrency:`
block would apply to every job in the workflow, including `plan` — which
means a pull request's `plan` for an environment would sit queued behind
an unrelated in-progress `apply` for that same environment, defeating the
entire reason Plan 02-02 sized the runner pool to two independent
instances (so PR plans stay responsive while a main-branch apply is in
flight).

## Decision

Concurrency groups are named `terraform-core-<environment>` — per **stack**
(`core-network` is the stack name; Phase 6's stacks get their own
`terraform-<stack>-<environment>` groups) and per **environment** — refining
IAC-03's literal wording to match the actual state-file granularity rather
than the group boundary the requirement's prose alone would imply.

The `concurrency:` block is declared **inside the `apply` job only**,
never at workflow level:

```yaml
apply:
  ...
  concurrency:
    group: terraform-core-${{ matrix.env }}
    cancel-in-progress: false
```

Job-level scoping means `plan` carries no `concurrency:` block at all — a
pull request's plan for `dev` is never blocked by a concurrent `apply`
for `dev`; the two jobs are independent from the scheduler's point of
view, constrained only by ordinary runner-pool capacity, not by an
artificial group dependency neither job actually needs.

## Consequences

* **What the group guarantees:** two `apply` runs targeting the same stack
  and environment never run at the same time. Drill scenario 1
  (`docs/drills/concurrency-queue.md`) proved this live — RUN2
  ([30875568486](https://github.com/AuraBit/athena-infra/actions/runs/30875568486))
  sat `queued` for the entire window RUN1
  ([30875491003](https://github.com/AuraBit/athena-infra/actions/runs/30875491003))
  held the `terraform-core-dev` group, and RUN2's own start
  (`03:47:29Z`) is strictly later than RUN1's completion (`03:46:28Z`).
* **What the group does not guarantee:** that the second run to *arrive*
  is the second run to *apply*. GitHub holds at most one pending run per
  concurrency group — a third arrival supersedes the pending one rather
  than joining a queue behind it — so arrival order and apply order are
  not a guarantee this mechanism makes, only something this estate's runs
  have so far always observed to coincide. The correctness control that
  actually matters — no two applies for one environment ever writing state
  at the same time — is the S3 native state lock (`use_lockfile = true`,
  Plan 02-01), not the concurrency group; the concurrency group is what
  keeps runs from piling onto that lock and contending for it in the first
  place. Both matter; only one is an ordering promise.
* **The job-scoping half is proven, not merely argued from the source.**
  Drill scenario 3 dispatched a held `apply (dev)`
  ([30876065871](https://github.com/AuraBit/athena-infra/actions/runs/30876065871))
  and, while it was still `in_progress`, opened a real pull request whose
  `plan (dev)` job reached `in_progress` within about a minute — never
  `queued` behind the apply's group — confirming that a workflow-level
  block would have caused exactly the false-queuing this repository's
  inline comment warns against, and that the current job-level placement
  avoids it.
* Every environment and stack this estate ever adds gets its own group for
  free from the same naming pattern — no new decision required per stack,
  only the same `terraform-<stack>-<environment>` substitution Phase 6's
  workflows copy verbatim.
