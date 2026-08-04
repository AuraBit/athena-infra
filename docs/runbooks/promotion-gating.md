# Runbook: Promotion Gating (D-04)

**When to use this:** whenever a later phase wires a workflow job that needs
to pause for human approval before it changes `stg` or `prod` — Phase 2's
`terraform apply` gate and Phase 3's GitOps promotion-commit job both bind
to the exact pattern recorded here. This document is the design contract
those phases implement against; read it before writing the job, not after.

**Status (Plan 02-06): live, not forward-looking.** Phase 2's gate is built.
`.github/workflows/terraform-core-network.yml`'s `apply` job declares
`environment: ${{ matrix.env }}`, bound at the job level (not per-step), and
`governance/environments.tf` (Plan 02-06) provisions the six Environments
that binding resolves against on `athena-infra`: `dev`, `stg`, `prod` (the
apply job's targets — `stg`/`prod` carry a `reviewers` block naming the
human developer, `dev` carries zero protection rules) and `dev-plan`,
`stg-plan`, `prod-plan` (read-only counterparts for a future `plan`-job
Environment binding, gated identically to nothing — see
`environments.tf`'s own header for the plan-vs-apply split's reasoning).
The rest of this document describes the general pattern both this stack and
Phase 3's gitops promotion-commit job implement; the paragraph above is
what actually exists today.

## Where the gate attaches

The gate binds to the **promotion-commit job** — the workflow job that
writes the change that actually promotes an environment — not to any later
consumer of that change. Concretely:

- On `athena-gitops`, the promotion-commit job is whatever writes to
  `envs/stg/` or `envs/prod/` (an image-tag bump, a manifest change). That
  job's YAML declares `environment: stg` or `environment: prod`, which
  binds it to the matching `github_repository_environment` resource this
  plan created (`environments.tf`). GitHub pauses that job — not the PR, not
  the commit, the job itself — until a `team-platform` reviewer approves it
  in the Actions run UI.
- On `athena-infra` (Phase 2), the same pattern gates `terraform apply`:
  the apply job for the stg/prod workspace declares the matching
  Environment, and GitHub pauses it identically before any real
  infrastructure change lands.
- `dev` has no `github_repository_environment` protection rules at all
  (verified live, `protection_rules` length `0`) — promotion into `dev` is
  unconditional and automatic. Only `stg` and `prod` pause.

The Environment is the gate. Nothing about branch protection, CODEOWNERS,
or the merge queue participates in this specific control — those govern
*getting a change into `main`*; Environments govern *what that change is
allowed to do once it's there*. They compose (a promotion-commit job still
has to pass `main`'s ruleset to exist at all), but they are two independent
controls, not one mechanism wearing two names.

## Why ArgoCD auto-sync stays on

ArgoCD's auto-sync is **not** part of this gate and is deliberately left
enabled in every environment, including `stg` and `prod`. Two independent
reasons:

1. **Phase 3's drift-revert demonstration depends on it.** That drill
   intentionally introduces live drift in a cluster (a manual `kubectl edit`
   against a running Deployment) and shows ArgoCD reverting it back to
   what's declared in git. If auto-sync were disabled to "add a gate,"
   that demonstration — a core piece of this project's GitOps interview
   story — would stop working, and the resulting gate would be redundant
   with the Environment approval anyway.
2. **The gate already happened upstream, correctly.** By the time ArgoCD
   sees a new commit in `envs/stg` or `envs/prod`, a human has already
   approved the job that wrote it. Making ArgoCD *also* pause to sync that
   already-approved change would be gating the same decision twice, in the
   wrong place — ArgoCD's job is to keep the cluster honest to git, not to
   decide whether a promotion should happen.

If a future phase ever needs to demonstrate "hold a sync for manual OK"
as its own distinct interview topic, that's a different, additive control
(an ArgoCD `SyncWindow` or manual sync policy) layered on top of this one —
not a replacement for it, and not something this plan enables.

## What the approver sees

The promotion workflow prints the rendered manifest diff (or, for Phase
2's Terraform gate, the `terraform plan` output) into the run's job
summary before pausing for approval. The reviewer is approving a visible,
concrete change — not a job name and a green checkmark. A gate a human
can't actually evaluate is security theatre; this is the requirement that
keeps it from becoming that.

## The solo-developer approval limitation, stated honestly

On this estate, the developer is both the author of most changes and the
only human `team-platform` reviewer available to approve a paused
Environment job. GitHub does not prevent a user from approving a
deployment on a PR/commit they themselves authored (`prevent_self_review`
defaults to `false` on `github_repository_environment`, and this plan does
not set it to `true`). This project does not pretend otherwise: a solo
estate cannot fully simulate the separation-of-duties story a multi-person
platform team provides, and this limitation is recorded here rather than
worked around with a fake second identity. What the gate *does* still
prove, faithfully: the mechanism itself — a paused job, a visible diff, an
explicit approval action recorded in the Actions audit log — behaves
exactly as it would in a multi-person org. The only thing missing is a
second person, not the control.

## How to verify the gate is real

Two levels, matching this plan's own verification split:

1. **From the outside (automated, `scripts/verify-governance.sh`):**
   confirms `stg` and `prod` on `athena-app` and `athena-gitops` carry a
   `required_reviewers` protection rule and a protected-branches deployment
   policy, that `dev` carries neither, and that the reviewing team is
   `team-platform`. This proves the *configuration* is correct but not that
   a real job actually pauses — a ruleset existing is not a ruleset that
   blocks, the same caveat this plan's other verification carries.
2. **With a real run (manual, once a promotion-commit job exists — Phase 2
   for `terraform apply`, Phase 3 for the GitOps commit):** trigger the job,
   confirm it stops at "Waiting for approval" in the Actions UI rather than
   running straight through, approve it as the `team-platform` reviewer,
   and confirm it proceeds only after that approval. This is the same class
   of check as this plan's protected-merge walkthrough (Task 3's human
   check) — a paused status the API reports is still not proof the job
   would actually have executed if left unapproved, until someone watches
   it not execute.

No such job exists as of this plan — Phase 2 and Phase 3 are the first
consumers of this pattern, and both should link back to this runbook
instead of re-deriving the design.
