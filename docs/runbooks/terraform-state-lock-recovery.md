# Runbook: Terraform State-Lock Recovery (D-33, D-07)

**When to use this:** a `terraform plan`/`apply` — locally or in
`terraform-core-network.yml`'s `apply` job — fails with `Error acquiring the state
lock`, and you need to decide whether that lock is genuinely stale (safe to clear) or
still held by a run that is legitimately still working (in which case clearing it would
be actively dangerous).

**The one-line posture (read this before doing anything else):** `terraform
force-unlock` is trivially easy to run and occasionally catastrophic. Breaking a lock
that a live run still holds is how two applies end up writing the same state at the
same time — the exact corruption the lock exists to prevent. **This runbook's Confirm
section comes before its Fix section on purpose, and is not optional to skip.** Reading
the lock, checking whether its holder is still alive, and — if it is — *waiting*, are
all first-class, correct outcomes of following this runbook. Reaching straight for
`force-unlock` because a pipeline is red and someone is watching is the exact failure
mode this ordering exists to prevent.

## Symptom

- A `terraform plan` or `terraform apply` fails immediately with:
  ```
  Error: Error acquiring the state lock
  Error message: operation error S3: PutObject, ... api error PreconditionFailed: ...
  Lock Info:
    ID:        <lock-id>
    Path:      <bucket>/<key>
    Operation: OperationType<Plan|Apply>
    Who:       <user>@<host>  (or, in CI, the runner's identity)
    Created:   <timestamp>
  ```
- In `terraform-core-network.yml`, this shows as the `apply` job's `terraform plan`
  or `terraform apply` step failing red, with the above error in the step log.
- Locally, the same error appears immediately (Terraform's default `-lock-timeout` is
  `0s` — no retry, no wait, an immediate failure naming the holder).

**Not this runbook, if:** the failure is a genuine Terraform error inside a resource
(a LocalStack API error, a dependency-ordering problem) rather than
`Error acquiring the state lock` — that is `docs/runbooks/terraform-apply-failure.md`'s
scope, not this one. The two runbooks are related (a killed apply job is exactly how a
stale lock gets created in the first place — see that runbook's own "Stale lock check"
section, which points here) but distinct failure modes: that runbook is about a
*partial apply*, this one is about a *lock nobody released*. They must not contradict
each other, and this runbook's Fix step (a new plan/apply cycle, never a destroy) is
deliberately the same fail-forward posture that runbook already commits this estate to.

## Confirm (before anything else — this section is the point of this runbook)

**1. Read the lock object's contents.** It records who took the lock, on what
operation, and when:

```bash
cd estate/athena-infra
. scripts/tf-env.sh <env>   # exports this env's non-secret AWS_* values

aws --endpoint-url http://localhost:4566 s3api get-object \
  --bucket "athena-tfstate-<env>" \
  --key "core-network/terraform.tfstate.tflock" \
  /tmp/lock.json
cat /tmp/lock.json | jq .
```

This is the same information Terraform's own `Error acquiring the state lock` message
already prints (`Lock Info:` block) — reading the object directly is for when you want
to confirm it independently, or when you only have the lock ID and need the rest.

**2. Check whether the recorded holder is still alive.** The check differs by where
the lock was taken:

- **If `Who` and the surrounding context point to a CI run** (the lock was taken by
  `terraform-core-network.yml`'s `apply` job): open the run the lock names — or, if you
  only have the lock's timestamp, `gh run list --workflow terraform-core-network.yml`
  around that time — and read its status.
  ```bash
  gh run view <run-id> --repo AuraBit/athena-infra
  ```
  `in_progress` → the holder is still working; go to "If the holder is still running"
  below. `completed`/`cancelled`/`failure` → the holder is gone; the lock is a genuine
  orphan (its own deferred unlock never ran — a killed job, a runner that stopped mid
  apply, a timeout). Continue to Fix.

- **If `Who` points to a local user (`<user>@<host>`)**: check whether that process
  still exists.
  ```bash
  # Locally, on the machine named in `Who`:
  ps aux | grep terraform
  # or, if you have the PID from your own session history:
  kill -0 <pid>   # exit 0 = still alive; nonzero ("no such process") = confirmed gone
  ```

**3. Only when the holder is provably gone is `force-unlock` the correct action.**
"Provably" means step 2 above returned a definite answer (a completed/cancelled CI run,
or a confirmed-dead local process) — not "it's been a while" or "probably done by now."

**4. If the holder is still running, the correct action is to wait.** This is its own
explicit, correct outcome — not a fallback for when you can't be bothered to
force-unlock. Re-run the Confirm steps once the holder's run/process has actually
finished. A pipeline sitting red while a legitimate run finishes is working exactly as
designed; racing to clear the lock underneath it is the actual incident.

## Fix (only after Confirm establishes the holder is genuinely gone)

```bash
cd estate/athena-infra
. scripts/tf-env.sh <env>
cd envs/<env>/core-network

terraform force-unlock -force <lock-id>
```

Then confirm the next operation succeeds — this is the *only* fix. **Never**
`terraform destroy`, delete the lock object by hand, or otherwise route around
Terraform's own unlock command — see "The standing rule" below for why.

## Verify

```bash
cd estate/athena-infra
. scripts/tf-env.sh <env>
cd envs/<env>/core-network

terraform plan -input=false -detailed-exitcode   # expect exit 0 — no lock, no drift
```

From the repo root, also confirm the standing lock-mechanics proof still holds and the
lock object is genuinely gone:

```bash
bash scripts/verify-tfstate-locking.sh
aws --endpoint-url http://localhost:4566 s3api head-object \
  --bucket "athena-tfstate-<env>" \
  --key "core-network/terraform.tfstate.tflock"   # expect 404 Not Found
```

## Prevention: why this should be rare in this estate's own CI

`terraform-core-network.yml`'s `apply` job declares
`concurrency: { group: terraform-core-<env>, cancel-in-progress: false }` — this is
what stops two CI applies for the *same* environment from ever contending for the lock
in the first place (D-33's concurrency-queue drill,
`docs/drills/concurrency-queue.md`, proves the second run queues rather than races).
Given that, **a lock contention seen in CI for a single environment means either a run
outside this workflow acquired it (a local `terraform apply` left running, another
tool, a manual operator session) or a genuinely stuck lock from a run that has since
died** — the concurrency group already rules out "two of this workflow's own CI runs
raced each other for the same environment" as the cause. That narrows the diagnosis in
Confirm step 2 immediately: check for a stray local process or a manual session before
assuming a CI run is the culprit.

## The standing rule

**A lock is never bypassed to make a red pipeline green.** Disabling locking
(`-lock=false`), deleting the lock object by hand instead of using
`terraform force-unlock`, or reaching for a lock table as an alternative mechanism are
all ways of turning a *visible* failure into an *invisible* one — the state lock exists
specifically to make concurrent-write corruption loud instead of silent (IAC-02), and
routing around it defeats that purpose regardless of how the routing is done. The lock
is either diagnosed and deliberately released with a recorded reason (this runbook's
Confirm-then-Fix procedure, done live, with the command and lock ID this document
records — see `docs/drills/stale-lock-recovery.md`), or it is waited out. There is no
third option this estate endorses.
