# Runbook: Terraform Apply Failure (Fail Loud, Fix Forward)

**When to use this:** a `terraform apply` step in `terraform-core-network.yml`'s
`apply` job (or any later Terraform-stack workflow that copies this pattern —
Phase 6 reuses this shape) failed partway through, and the job reported red.
This is the honest, enterprise-normal answer to "what happens when apply
fails in production" — CONTEXT.md flags this exact question as interview
material, and this runbook is that answer written down before any apply has
actually failed, per D-07.

**The one-line posture (read this before doing anything else):** an apply
that fails partway through leaves **real resources created and recorded in
state**. There is no automatic rollback, and no automatic retry of any
state-mutating step, anywhere in this estate's Terraform CI — deliberately.
A `terraform destroy` triggered automatically by a failed apply is how a
partial outage becomes a total one: the destroy itself can fail partway too,
and now two separate partial operations have to be reasoned about instead of
one. A blind automatic retry against a half-applied stack can compound the
original failure in ways that are much harder to diagnose after the fact
than the original error message was. Both temptations are rejected here on
purpose. The fix is always **forward** — a new pull request, reviewed like
any other change — never an automated undo.

## Symptom

- The `apply` job (or a specific matrix leg, e.g. `apply (dev)`) in
  `terraform-core-network.yml` shows red in the Actions UI.
- The failing step is `terraform apply -input=false tfplan` itself (not the
  `terraform plan` step before it, and not the `scripts/verify-network.sh`
  step after it — those are different failure modes with different
  procedures; see "Not this runbook" below).
- The job's log shows Terraform's own error for the specific resource that
  failed (a LocalStack API error, a dependency-ordering problem, a timeout)
  followed by Terraform's own summary of what it did and did not manage to
  apply before stopping.

**Not this runbook, if:**
- The `terraform plan` step itself failed (before any apply began) — that is
  a plan-time error (bad HCL, a broken module reference, an unreachable
  LocalStack endpoint). Nothing was applied; there is no partial state to
  reason about. Fix the plan-time error and re-push.
- `scripts/verify-network.sh <env>` failed **after** `terraform apply`
  reported success — that is IAC-04's fake-success detector doing its job
  (`apply` exiting 0 is not proof the resource is real against a
  license-gated or misbehaving LocalStack service; see
  `docs/localstack-service-coverage.md`). Confirm whether the resource
  genuinely didn't create (proceed with this runbook, state is likely
  correct and the resource is genuinely missing) or whether LocalStack
  itself misbehaved on the read side (a `verify-network.sh` re-run after
  confirming LocalStack's health may simply pass).
- The job died holding the state lock (a killed job, a runner that got
  stopped mid-apply, a timeout) rather than reporting a clean Terraform
  error — see "Stale lock" below, and Plan 02-09's dedicated stale-lock
  recovery runbook once it exists.

## Confirm

Before writing a single line of remediation HCL, find out what state
**actually** records — never assume the apply's own log is the full picture,
and never assume "it failed" means "nothing changed":

```bash
cd estate/athena-infra
. scripts/tf-env.sh <env>              # exports this env's non-secret AWS_* values
cd envs/<env>/core-network

terraform init                          # re-attach to the S3-backed state
terraform state list                    # exactly what Terraform believes exists right now
terraform show                          # full attribute detail for every resource in state
terraform plan -detailed-exitcode       # 0 = state matches config+reality, 2 = drift, 1 = error
```

`terraform plan -detailed-exitcode` after a partial apply almost always
reports exit code `2` (there is a real diff between what's in state now and
what the full config wants) — that is expected, not itself a new problem.
Read the plan output carefully: it tells you exactly which resources
Terraform still needs to create, update, or (occasionally, if a
partially-applied dependency chain left something in an inconsistent
in-between state) replace, to reach the fully-converged state the config
describes.

**Stale lock check, if the job died rather than erroring cleanly:**

```bash
aws --endpoint-url http://localhost:4566 s3api head-object \
  --bucket athena-tfstate-<env> --key core-network/terraform.tfstate.tflock \
  2>&1 || echo "no lock object present"
```

If a `.tflock` object exists and you have confirmed (via the Actions UI —
`gh run list`, `gh run view <id>`) that no job is currently running against
this env's stack, the lock is stale and blocks every future `terraform
plan`/`apply` until cleared. **Do not `force-unlock` reflexively** — confirm
first that the job that held it is genuinely no longer running, then follow
Plan 02-09's dedicated stale-lock recovery runbook once it lands (this
runbook's own scope is the apply-failure procedure, not lock recovery
mechanics — the two are related but distinct failure modes, and conflating
them is how a lock recovery accidentally becomes a second concurrent apply
against already-partial state).

## Fix

1. **Read the failure.** Terraform's own error message for the specific
   resource that failed is almost always specific enough to act on directly
   (a LocalStack API limitation, a missing dependency, a value that failed a
   provider-side validation). Do not skip straight to "just re-apply" without
   reading what actually broke — a blind retry against the same root cause
   just fails the same way again, one CI run later.

2. **Decide: is the fix forward, or does a specific resource need targeted
   remediation?**
   - **Fix forward (the common case):** the root cause is a config problem
     (a typo, a missing variable, a resource ordering issue, a value that
     needs to change). Open a new pull request with the fix, exactly like
     any other change — it goes through `static`, `plan`, human review, and
     merge like every other Terraform change in this estate. The next
     `apply` re-plans against current state (D-05) and picks up cleanly
     from wherever the partial apply left off; Terraform's own dependency
     graph handles "some resources already exist, some don't" correctly as
     long as the config is correct.
   - **Targeted remediation (rarer):** a specific resource landed in a state
     Terraform's normal apply cycle can't cleanly reconcile on its own (for
     example, a resource that half-created and needs to be imported,
     tainted, or removed from state before a clean re-apply can proceed).
     Use `terraform state rm`/`terraform import`/`terraform apply -replace`
     deliberately and locally first (against this env's real state, with
     `tf-env.sh` sourced), confirm the result with `terraform plan
     -detailed-exitcode` showing a clean diff, then open the pull request
     that captures the resulting config change (if any) for review — never
     leave a manual state operation undocumented and unreviewed.

3. **Never run `terraform destroy` as a response to a failed apply.** This
   is D-07's central point, restated plainly: destroying a partially-applied
   stack does not undo the failure, it adds a second state-mutating
   operation on top of the first one, with its own chance of failing
   partway through. If a resource genuinely needs to be removed, that is a
   deliberate, reviewed change captured in a pull request like any other —
   not an emergency response to a red CI run.

4. **Never auto-retry a state-mutating step.** If a transient LocalStack
   issue (not a config problem) caused the failure, confirm LocalStack's own
   health first (`bash scripts/verify-localstack.sh`), then re-run the
   **same, unmodified** pull request's merge (or push a no-op commit if the
   PR already merged) — this produces a fresh `terraform plan` per D-05, not
   a resumption of the failed apply, and that fresh plan is what actually
   gets applied. Do not click "re-run failed jobs" and hope; the re-run's own
   fresh plan is the thing that needs to be correct, and confirming
   LocalStack's health first is what tells you whether re-running is even
   the right move.

## Verify

```bash
cd estate/athena-infra
. scripts/tf-env.sh <env>
cd envs/<env>/core-network
terraform plan -detailed-exitcode      # expect exit 0 — no remaining diff
```

Then, from the repo root, run the stack's own post-apply verification the
same way the CI job would:

```bash
bash scripts/verify-network.sh <env>   # IAC-04 — apply green + resource real, independently confirmed
bash scripts/verify.sh network         # full network-area dispatcher
```

Both must pass before considering the stack recovered. A `terraform plan
-detailed-exitcode` reporting `0` alone is not sufficient — it proves
Terraform's own state matches its own config, not that the resources are
real against LocalStack (exactly the fake-success gap IAC-04 exists to
close; see Pitfall 2 in `.planning/phases/02-core-network-terraform-ci-verification-pattern/02-RESEARCH.md`).

## Reasoning, for the record

Fail loud, fix forward is not a limitation of this estate's tooling — it is
the deliberate, enterprise-normal answer, and pretending otherwise (an
automatic rollback that "just works," an automatic retry that "just
succeeds the second time") is exactly the false confidence a study project
like this one exists to teach distrust of. Partial state is **kept, not
discarded**: the alternative — some kind of automatic state reset on
failure — would throw away the one piece of ground truth (what Terraform
actually managed to create before it stopped) that the fix-forward pull
request needs in order to converge cleanly on the next apply. This is the
same "keep the truth, don't paper over it" instinct `scripts/verify-network.sh`
already embodies for a different failure mode (apply reporting success on a
resource that isn't real) — here it is state that partially changed, there
it is state that claims success it hasn't earned; both get handled by
looking honestly at what's actually there, not by wishing the failure away.
</content>
