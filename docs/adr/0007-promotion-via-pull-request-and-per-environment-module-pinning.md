# 0007. Promotion via Pull Request and Per-Environment Module Pinning

* Status: accepted
* Date: 2026-08-04
* Deciders: Yahia Tarek (YahiaEng)
* Tier: long-form

## Context

This estate's Terraform layout is folder-per-environment (`athena-docs`
ADR-0004): `envs/dev/core-network`, `envs/stg/core-network`, and
`envs/prod/core-network` are three independent Terraform roots, each with
its own state file, each pinning whatever module version it happens to be
running *right now* — not necessarily the same version as its siblings.
Phase 2 needed two coupled decisions on top of that layout: **how a change
reaches a higher environment**, and **how an environment root declares
which version of a module it runs**.

The honest starting point is that a large share of enterprise teams do not
run this shape at all. The pattern a Deloitte- or VOIS-tier interviewer is
most likely to have run personally is the Azure DevOps classic shape: **one
pipeline, one commit, multiple gated stages** — `dev` → `stg` → `prod` —
where each stage's approval promotes the *same build artifact* forward
unchanged. That model has real, non-trivial strengths, and stating them
weakly here would make this ADR a straw man rather than a genuine decision
record:

* **One artifact, demonstrably identical across environments.** The exact
  binary or container image that passed dev is the exact one running in
  prod — there is no window in which "what's in dev" and "what's in prod"
  could be two different builds of allegedly the same change.
* **A single run's timeline shows the whole promotion.** One pipeline run
  ID, one page to open, and the reviewer sees every stage a change passed
  through and every approval it collected, in order, in one place.
* **No environment can be pinned to something nobody remembers pinning.**
  Because promotion is stage-gating on one artifact rather than a
  per-environment reference, there is no separate "which version does prod
  point at" fact that can go stale independently of the pipeline's own
  history.

Those are real advantages, and for a system whose actual deployable unit is
a single build artifact moving through environments unchanged (a compiled
binary, a container image), the multi-stage same-commit pipeline is the
correct, production-grade choice. It loses here on one specific,
structural criterion, not on being old-fashioned or on any stylistic
preference:

**This repository has no single artifact to promote.** `envs/dev/core-network`,
`envs/stg/core-network`, and `envs/prod/core-network` are not three stages
of one pipeline running one build — they are three independent Terraform
roots, each declaring its own state and its own account (ADR-0009), each
free to pin a different module version at any given moment. A multi-stage
pipeline's entire mental model assumes one thing moving through gates in
lockstep; folder-per-environment's entire mental model assumes the
opposite: each environment's pinned reference is its own fact, changed on
its own schedule, by its own reviewed diff. Forcing the multi-stage shape
onto this layout would mean writing a pipeline that reads "which
environment is this stage" out of a stage name or a pipeline variable
rather than out of the repository itself — and the moment that happens,
the audit question "what is running in prod right now" stops being
answerable by reading a file in the repo. It becomes answerable only by
tracing which pipeline run last reached the prod stage and what it carried,
which requires pipeline-run history, not just the repository's own current
state. Both shapes are correct, production-grade patterns for their
layout — the layout was chosen first (ADR-0004), and this decision follows
from it rather than being re-litigated against it.

## Decision

**Promotion happens through a pull request that bumps one environment's
pinned module `?ref=`.** Promoting `stg` to a new `core-network` version is
a one-line diff to `envs/stg/core-network/main.tf`, in its own pull
request, reviewed and merged through the same pipeline (`static` / `plan`
/ `gate`) as any other change to this repository, and gated by that
environment's own GitHub Environment protection rule
(`docs/runbooks/module-release-and-promotion.md`, `governance/
environments.tf`). Rolling back is the identical mechanism run in reverse
— another pull request, pinning the previous tag — not a separate
rollback pipeline or a direct state edit.

**Modules are pinned by git tag, never by relative path.** A module
release is an annotated tag on `main`, `modules/<module-name>/vMAJOR.MINOR.PATCH`
(e.g. `modules/core-network/v1.0.0`), cut only once the tagged commit's own
`terraform test` suite and static gate have already passed CI
(`docs/runbooks/module-release-and-promotion.md` Part 1). An environment
root's `source` argument resolves against that tag's `?ref=`, not against
`../../../modules/core-network` or any other relative path. If environment
roots instead used a relative-path source, every environment would
silently track whatever is on `main` at apply time — the moment the module
changed, dev and prod would be running identical code without either
having gone through a promotion, and the pull request that was supposed to
be the audit trail for "prod is now running the new version" would be a
no-op nobody noticed. Pinning by tag makes that impossible by construction:
an environment's code only changes when its own `?ref=` line changes, and
that line only changes inside a reviewed pull request.

A private module registry (publishing tagged releases to a registry rather
than resolving git refs directly) is the natural next step once this
estate needs to share modules outside this one repository, or wants
registry-level version constraints and provenance metadata. It is
deliberately deferred — git-tag pinning already gives every property this
phase's requirements need (an immutable, reviewable, per-environment
reference), and a registry adds operational surface (hosting, publishing
credentials, a second place versions can drift from the tag that produced
them) this estate does not yet need to carry.

## Consequences

* **Three pull requests to reach prod, not one pipeline run.** Promoting a
  change through dev, stg, and prod is three separate, sequential pull
  requests (Plan 02-08 exercised exactly this: PR #33 promoted dev,
  PR #34 promoted stg, PR #35 promoted prod — three merges, three
  `apply` runs, not one). An interviewer used to a single-pipeline
  promotion view will correctly notice this is a different, and by one
  measure slower, path to prod.
* **Environments can drift apart, and nothing currently detects it.**
  Because each environment's pin is its own independent fact, a promotion
  that is simply forgotten — stg gets bumped, prod does not — leaves prod
  running an old module version with no automated signal that it has
  fallen behind. Scheduled drift detection (a periodic job comparing each
  environment's pinned ref against the latest tag, or against its
  siblings) was deliberately deferred; today, noticing drift is a manual
  read of three `main.tf` files.
* **A module change is not exercised against prod's actual inputs until
  prod's own promotion runs.** Dev's promotion plan showing "No changes"
  says nothing about what stg's or prod's promotion plan will show — each
  environment's own state and inputs are the only thing that can prove a
  given version applies cleanly there. This is the direct cost of "no
  single artifact tested once and promoted unchanged": each environment
  re-proves the module against its own reality, which is also, from
  another angle, exactly the point (ADR-0009's account-per-environment
  isolation means stg's inputs are never assumed identical to prod's).
* **Live evidence this mechanism is real, not aspirational:** the dev
  promotion pull request (PR #33, bumping `?ref=` from `v0.6.0` to
  `v1.0.0`) planned **zero resource replacements** — confirming that
  cutting `v1.0.0` on content identical to the already-applied `v0.6.0`
  is exactly what a pure version-one release tag should show, and that
  the ref-bump mechanism itself introduces no unintended drift. stg's
  (PR #34) and prod's (PR #35) promotion runs were both observed paused
  at "Waiting for approval" in the Actions run UI before the human
  reviewer (D-31's carve-out) approved them — the moment that actually
  proves the gate is real rather than merely configured.
