# Runbook: Module Release and Promotion (D-03, D-04)

**When to use this:** cutting a new version of a module under `modules/`
(today: `core-network`; Phase 6 adds more), and moving that version into
`dev`, `stg`, or `prod` one environment at a time. This is the mechanism
Plan 02-08 exercised for real, three times, to bring all three
`core-network` environments live.

## Part 1 — the release: what makes a change taggable, and how

A module version is cut, not committed — a tag is a promise that a named
set of resources and output names is stable enough for an environment root
to pin against. Two things must be true on `main` before cutting one:

1. **The module's own `terraform test` suite passes.** `modules/*/tests/`
   holds `mock_provider`-backed `.tftest.hcl` files (Plan 02-07, D-09) —
   these run in the `module-test` CI job on every pull request that touches
   `modules/**`, and must be green on the merge commit being tagged.
2. **The static gate is green on that same merged commit.** `terraform fmt
   -check`, `terraform validate`, and the hard-blocking Checkov scan
   (`static` job) all passed on the pull request that produced the commit
   being tagged.

Both are enforced by CI before merge, not re-checked at tag time — cutting
a tag on a commit that already passed `main`'s `gate` required check is
sufficient; there is no separate release pipeline.

### Why per-module, not per-repository, version numbers

The tag name is `modules/<module-name>/vMAJOR.MINOR.PATCH`
(`modules/core-network/v1.0.0`), never a single repository-wide version.
`athena-infra` is one repository holding multiple independent Terraform
modules — Phase 6 adds at least a `data-storage` and an
`application-compute` module alongside `core-network` — and those modules
change on unrelated schedules. A single repository-wide version number
would force every module to bump together every time any one of them
changed, which either (a) makes environment roots that pin unrelated
modules churn their ref on every release, or (b) trains reviewers to
stop reading version bumps as meaningful. Per-module tags mean a
`core-network` release never touches a `data-storage` env root's pinned
ref, and vice versa — each module's version number means exactly what it
says.

### The exact commands

```bash
cd estate/athena-infra

# 1. Confirm the commit being tagged already passed CI (module-test + static)
#    on its own merged pull request -- check the PR's checks, not the tag
#    creation itself.
git log --oneline -1                       # the commit to tag

# 2. Cut an ANNOTATED tag (never lightweight -- git cat-file -t must report
#    "tag", not "commit"; an annotated tag carries a message, a tagger and
#    a date, which is what makes `git tag -l -n1` and `git show` useful for
#    "what does this version actually contain" six months later).
git tag -a modules/core-network/v1.0.0 -m "modules/core-network v1.0.0: <one-line resource-set summary>.

<longer paragraph: what changed since the last tag, and which output
names other stacks now depend on through remote state -- Phase 6 reads
several of core-network's outputs this way, so naming them explicitly in
the tag message is what makes 'is this a breaking change' answerable
without re-reading outputs.tf.>
"

# 3. Push the tag -- a local-only tag promotes nothing; every env root's
#    ?ref= resolves against the remote.
git push origin modules/core-network/v1.0.0

# 4. Confirm it landed correctly.
git ls-remote --tags origin 'modules/core-network/v1.0.0'
git cat-file -t modules/core-network/v1.0.0   # must print: tag
```

## Part 2 — the promotion: bumping one environment's ref, in its own pull request

Promoting a module version into an environment is a one-line change: that
environment's `main.tf` `?ref=` argument, in a pull request that touches
nothing else. The walkthrough, identical for dev, stg and prod:

```bash
cd estate/athena-infra
git checkout main && git pull
git checkout -b promote/<env>-core-network-v<X.Y.Z>

# Change exactly one line.
sed -i 's#ref=modules/core-network/v<OLD>#ref=modules/core-network/v<NEW>#' \
  envs/<env>/core-network/main.tf

# Sanity-check the plan BEFORE opening the PR -- this is not the plan a
# human reviews (that happens in CI, posted as a sticky PR comment by the
# `plan` job), it's a local guard against opening a PR that will obviously
# show a bad diff.
. scripts/tf-env.sh <env>
(cd envs/<env>/core-network && terraform plan -input=false -no-color)
# ^ MUST show "No changes" or only genuinely-intended attribute changes.
# If ANY resource shows as "must be replaced" for what should be a pure
# ref bump, STOP -- the module's resource addressing changed between the
# old and new tag, which is a defect in the module, not something this
# promotion should paper over.

git add envs/<env>/core-network/main.tf
git commit -m "feat(<env>): promote core-network to modules/core-network/v<X.Y.Z>"
git push -u origin promote/<env>-core-network-v<X.Y.Z>
gh pr create --title "Promote <env> core-network to v<X.Y.Z>" --body "..."
```

Then watch the pipeline, exactly as any other pull request against this
repository:

1. `detect-changes` reports only `<env>=true` — D-08's change detection
   means this pull request's `plan` matrix fans out to exactly the one
   environment being promoted, never the other two.
2. `plan (<env>)` runs on the self-hosted runner and posts its output as a
   sticky comment (`core-network-<env>` header) — this is the diff a human
   reviewer is actually approving when they approve the pull request.
3. `static` and (if this pull request happens to also touch `modules/**`,
   which a pure promotion never does) `module-test` report.
4. `gate` aggregates all of the above into the one required check `main`'s
   ruleset points at.
5. Approve (`athena-ci-bot`'s automated review, per D-03's audit-trail
   pattern) and squash-merge.
6. The merge triggers `push` on `main`, which runs the `apply` job for
   every environment `detect-changes` reports changed — for a promotion
   pull request, that's the one environment just promoted. `apply` binds
   `environment: <env>` (`governance/environments.tf`, Plan 02-06):
   - **dev** carries zero Environment protection rules — the apply runs
     straight through, unattended, immediately after merge.
   - **stg and prod** carry a required-reviewer rule naming the human
     developer (D-31's carve-out — see `docs/runbooks/promotion-gating.md`
     for why the reviewer is a human, not `athena-ci-bot`). The apply job
     pauses at "Waiting for approval" in the Actions run UI until that
     review happens. Capture the run URL while it is paused, before
     approving — this is the one moment that actually proves the gate is
     real rather than merely configured.
7. Once approved (or immediately, for dev), `apply` runs a **fresh**
   `terraform plan` (never the pull request's saved plan artifact — state
   may have moved since the PR opened) and applies that. Its own
   `verify-network.sh <env>` step runs inside the same job, inheriting the
   `concurrency: terraform-core-<env>` group, so nothing can apply to that
   environment between the apply and the verification.

### Why per-environment pull requests, not a multi-stage same-commit pipeline

An interviewer with an Azure DevOps background will expect the other
shape: one pipeline, one commit, multiple gated stages (`dev` → `stg` →
`prod`), each stage's approval promoting the *same* build artifact
forward. That model is genuinely the right one — for a single deployable
artifact moving through environments unchanged (a container image, a
compiled binary). It does not fit this repository's layout, and the
mismatch is structural, not a matter of taste:

- **This repository is folder-per-environment, not artifact-per-pipeline.**
  `envs/dev/core-network`, `envs/stg/core-network` and
  `envs/prod/core-network` are three independent Terraform roots, each
  with its own state file, each pinning the module version it happens to
  be running *right now* — which is not necessarily the same version as
  its siblings. A same-commit multi-stage pipeline assumes one build
  reaching every stage in lockstep; this layout assumes the opposite: each
  environment's pinned ref is its own fact, changed on its own schedule,
  by its own reviewed diff.
- **A promotion pull request is a diff a reviewer can actually read.** "What
  exactly changed in stg" is answered by `git diff` on one file in one
  pull request. In a multi-stage pipeline, the equivalent question — "what
  is in stg right now" — is answered by tracing which pipeline run last
  reached the stg stage and what commit it carried, which requires
  pipeline-run history, not just the repository.
- **Reverting is symmetric with promoting.** Because each environment's
  pin is an ordinary file, rolling back stg is exactly the same mechanism
  as promoting it — another pull request, another reviewed diff (see
  "Rollback" below). A multi-stage pipeline's rollback is a different
  operation from its promotion (re-running an old pipeline stage, or a
  separate rollback pipeline entirely).

Both shapes are legitimate, production-grade patterns — which one is
correct follows from the repository's layout (folder-per-environment vs.
single-artifact-pipeline), not from which one is "more modern." The
flagship ADR this project writes for its promotion model (Plan 02-11)
carries the fuller version of this argument, including the trade-offs this
runbook only summarizes; this section exists so the mechanism is
documented where the mechanism actually runs, and links back to that ADR
rather than duplicating it.

## Rollback

A bad promotion is reverted the same way it was made: another pull
request, pinning the *previous* tag, reviewed and merged through the exact
same pipeline described above. There is no separate rollback mechanism,
no `terraform destroy`-and-reapply, no direct edit to state. This is
D-07's fail-forward posture applied to promotion specifically — a rollback
is not a special, higher-risk operation that bypasses review; it is an
ordinary promotion pull request whose diff happens to move a `?ref=`
backwards instead of forwards, subject to the identical plan review and
(for stg/prod) the identical human-approval gate as any other promotion.

```bash
git checkout -b rollback/<env>-core-network-v<OLD>
sed -i 's#ref=modules/core-network/v<BAD>#ref=modules/core-network/v<OLD>#' \
  envs/<env>/core-network/main.tf
# same review-and-apply cycle as any promotion above
```

## What Plan 02-08 recorded as evidence this mechanism is real

- **Dev promotion (v1.0.0):** promotion pull request's plan showed no
  resource replacements (module content at `v1.0.0` is identical to
  `v0.6.0`'s already-applied resources — the tag marks the module
  feature-complete, it does not change any resource). The merge produced
  an unattended `apply (dev)` run that completed and passed
  `verify-network.sh dev`.
- **stg promotion:** `envs/stg/core-network/` created and promoted the same
  way; its `apply` run was observed paused at "Waiting for approval"
  before being approved by the human developer.
- **prod promotion:** identical mechanism, third and final time this
  phase; its `apply` run was likewise observed paused before approval.

Run URLs and plan summaries for each of these are recorded in the
respective promotion pull requests' commit messages and in
`.planning/phases/02-core-network-terraform-ci-verification-pattern/02-08-SUMMARY.md`.
