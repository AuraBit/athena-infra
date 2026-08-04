# Drill: Stale-Lock Recovery (D-33, D-07)

**Date:** 2026-08-04
**Run by:** local commands against `envs/dev/core-network`'s real S3-backed state
(no CI involved — this drill runs directly against LocalStack, the way a human operator
would diagnose a genuinely stuck lock)
**Precondition confirmed first:** `bash scripts/verify-tfstate-locking.sh` passed (3/3)
before this drill began, confirming lock acquire/contention/release genuinely work
against this LocalStack account (Plan 02-01's own postcondition).

**Purpose:** Cause a real stale lock, capture the exact error Terraform produces, then
follow the diagnosis-then-deliberate-force-unlock procedure and confirm recovery — all
observed, not described. This is the failure signature RESEARCH names for Assumption A1
(a lock acquired and never released) and the recovery procedure is the thing you want
written down before you need it at speed.

## What was done

1. **Cause the lock:** started a real `terraform apply -input=false -auto-approve`
   against `envs/dev/core-network` as a background process (PID `3429095`).
2. **Wait for the lock:** polled `s3api head-object` for
   `athena-tfstate-dev/core-network/terraform.tfstate.tflock` — observed present after 2
   polls (~0.5s), at `2026-08-04T04:33:22Z`. The lock object's own contents at that
   moment:
   ```json
   {"ID":"44ffdaaf-baf9-dc5c-e96c-062d63624a5d","Operation":"OperationTypeApply","Info":"","Who":"aorus@arch","Version":"1.15.8","Created":"2026-08-04T04:33:21.350546715Z","Path":"athena-tfstate-dev/core-network/terraform.tfstate"}
   ```
3. **Kill mid-run:** `kill -9 3429095` at `2026-08-04T04:33:22Z`. SIGKILL is
   unblockable — the process cannot run its own deferred unlock, which is the point:
   this is what a killed CI job or a hard-crashed operator machine looks like, not a
   clean Ctrl-C.
4. **Confirm the lock survives the kill:** `aws s3api head-object` on the same key
   still returned `200` (`ContentLength: 228`, unchanged `ETag`) after the process was
   confirmed dead (`kill -0 3429095` → `no such process`).
5. **Confirm what state records:** `terraform state list` immediately after the kill
   shows the full, unchanged resource set (44 resources — the complete dev
   `core-network` module, VPC through flow-logs bucket). Nothing was half-created:
   dev's `terraform apply` had **no diff** to apply in the first place (dev was already
   fully converged before this drill started), so the killed apply never reached its
   own apply phase — it died holding the lock during its own refresh/plan phase. This
   is a genuinely honest limitation of this specific drill run worth stating plainly:
   it proves the lock-survives-a-kill and recovery-procedure claims fully, but it does
   **not** additionally demonstrate a *partially-applied* resource set, because there
   was nothing left to partially apply. `docs/runbooks/terraform-apply-failure.md`
   (already-composed, cross-referenced below) is the dedicated runbook for that
   distinct scenario (a failed apply that *did* have real resources to create).
6. **Attempt another operation, capture the exact error:**
   `terraform plan -input=false -no-color -lock-timeout=0s` produced:
   ```
   Error: Error acquiring the state lock

   Error message: operation error S3: PutObject, https response error
   StatusCode: 412, RequestID: dd404fd7-dbc8-425a-a712-1f4efc528c41, HostID:
   s9lzHYrFp76ZVxRcpX9+5cjAnEH2ROuNkd2BHfIa6UkFVdtjf5mKR3/eTPFvsiP/XV/VLi31234=,
   api error PreconditionFailed: At least one of the pre-conditions you
   specified did not hold
   Lock Info:
     ID:        44ffdaaf-baf9-dc5c-e96c-062d63624a5d
     Path:      athena-tfstate-dev/core-network/terraform.tfstate
     Operation: OperationTypeApply
     Who:       aorus@arch
     Version:   1.15.8
     Created:   2026-08-04 04:33:21.350546715 +0000 UTC
     Info:

   Terraform acquires a state lock to protect the state from being written
   by multiple users at the same time. Please resolve the issue above and try
   again. For most commands, you can disable locking with the "-lock=false"
   flag, but this is not recommended.
   ```
   The lock ID (`44ffdaaf-baf9-dc5c-e96c-062d63624a5d`), operation (`OperationTypeApply`),
   holder (`aorus@arch`), and creation timestamp all match the lock object's own JSON
   exactly — Terraform's error is reading the same object this drill inspected directly.
7. **Follow the recovery procedure** (`docs/runbooks/terraform-state-lock-recovery.md`):
   read the lock object's contents (already done, step 2/6 above) — confirmed the
   holder (`aorus@arch`, PID `3429095`) is genuinely gone (`kill -0 3429095` → exit 1,
   "no such process") — then, and only then,
   `terraform force-unlock -force 44ffdaaf-baf9-dc5c-e96c-062d63624a5d`:
   ```
   Terraform state has been successfully unlocked!

   The state has been unlocked, and Terraform commands should now be able to
   obtain a new lock on the remote state.
   ```
8. **Confirm recovery:** the next operation succeeded cleanly —
   `terraform plan -input=false -detailed-exitcode` refreshed all 44 resources and
   reported `No changes. Your infrastructure matches the configuration.`, exit `0`.
   The fix here was **a new plan/apply cycle against existing state, never a
   `terraform destroy`** — the same fail-forward posture
   `docs/runbooks/terraform-apply-failure.md` already commits this estate to for a
   failed apply generally; this drill's recovery is a specific instance of that same
   posture, not a separate one.

## Post-drill health check

- `s3api head-object` on the lock key: `404 Not Found` (lock genuinely gone).
- `bash scripts/verify-tfstate-locking.sh`: **3 passed, 0 failed** (acquire, contention,
  release all still hold against this account after the drill).
- `terraform plan -input=false -detailed-exitcode` in `envs/dev/core-network`: exit `0`,
  no drift.
- No `.tflock` object remains under `core-network/` in any of the three state buckets
  (`athena-tfstate-dev`, `athena-tfstate-stg`, `athena-tfstate-prod`) — confirmed via
  `head-object` returning `404` on all three.

The environment was left exactly as healthy as it was before this drill began.

## See also

- `docs/runbooks/terraform-state-lock-recovery.md` — the general procedure this drill
  exercised (Confirm before Fix, waiting as an explicit outcome, the force-unlock
  command with a placeholder).
- `docs/runbooks/terraform-apply-failure.md` — the fail-forward posture (new apply,
  never a destroy) this drill's recovery step composes with; that runbook's own "Stale
  lock check" section already pointed forward to this drill before it existed.
- `scripts/verify-tfstate-locking.sh` — the standing, repeatable proof that acquire /
  contention / release genuinely work against this LocalStack account; this drill's
  precondition and post-drill health check both lean on it.
