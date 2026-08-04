# 0009. Simulated Account-per-Environment, State Bucket per Account

* Status: accepted
* Date: 2026-08-04
* Deciders: Yahia Tarek (YahiaEng)
* Tier: short-form

## Context

The strongest environment-isolation boundary AWS offers is not an IAM
policy or a VPC — it is a separate account. Large organizations run
landing-zone architectures precisely because "different account" makes
whole classes of cross-environment mistake structurally impossible rather
than merely policy-forbidden: a set of credentials scoped to the dev
account cannot see, list, or touch anything in the stg or prod account,
full stop, independent of whatever IAM policy someone did or didn't write
correctly. This phase needed to decide whether to simulate that boundary
locally, on a free LocalStack tier, or fall back to a weaker
name-and-tag-based separation inside one shared account (CONTEXT.md D-16
flagged this explicitly as verify-at-execution, with the fallback
documented in advance rather than improvised if the simulation failed).

## Decision

Each environment uses a distinct simulated twelve-digit account ID
(`dev=111111111111`, `stg=222222222222`, `prod=333333333333`), which
LocalStack derives its account namespace from the access-key ID a request
carries — no separate account-provisioning step, no LocalStack-side
configuration beyond each environment's own credentials being distinct.
Each account holds its own Terraform state bucket
(`athena-tfstate-<environment>`), with object keys namespaced per stack
(`core-network/terraform.tfstate` today; Phase 6's stacks add sibling keys
in the same bucket rather than new buckets).

**The simulation held; the documented fallback was not needed.** Plan
02-08 confirmed live, under each environment's own credentials: `sts
get-caller-identity` reports the correct account ID for that environment,
`s3 ls` lists only that environment's own state and flow-log buckets (no
cross-environment bucket visibility), and each environment's own `/16`
supernet (`10.0.0.0/16`, `10.1.0.0/16`, `10.2.0.0/16`) appears in exactly
one account's VPC list and none of the others'. (One honest wrinkle,
recorded rather than smoothed over: LocalStack itself seeds an identical
default VPC — `172.31.0.0/16` — under every simulated account. That VPC is
LocalStack's own scaffolding, not an Athena-managed resource, and its
presence in all three accounts is not cross-environment leakage; the
invariant that actually matters — no environment's own supernet or
state/flow-log bucket is visible from another environment's credentials —
held in every account checked.)

**This phase inherits, rather than re-makes, Phase 1's threat acceptance
for the unauthenticated LocalStack port** (`0004-localstack-as-a-host-service.md`).
The state files and their lock objects sit behind `localhost:4566` /
`host.k3d.internal:4566` with no authentication of their own — accepted at
this estate's ASVS L1 because the emulated account holds no real
credentials or data and the port is reachable only from the local host or
inside the local cluster. That acceptance was made once, for the LocalStack
service as a whole, in Phase 1; this phase's account-per-environment
simulation runs on top of it and does not weaken or strengthen it. An
inherited acceptance that is never written down here would be
indistinguishable from one nobody noticed when this phase's own state
buckets went live — recording the inheritance explicitly is the point of
this paragraph.

## Consequences

* Retrofitting account-per-environment after the fact would rewrite every
  environment's backend and provider block and orphan whatever state
  already existed under the old, undifferentiated configuration — this is
  exactly why it was decided and built in this phase's first task
  (Plan 02-01) rather than discovered as a gap later.
* Phase 6's `data-storage` and `application-compute` stacks add state keys
  to these same three buckets, under the same three accounts — no new
  account or bucket decision required, only the same per-stack key
  namespace this phase already established.
* The account boundary and the CIDR plan (`docs/ipam-allocation.md`)
  reinforce each other rather than one being an accident of the other:
  each environment is isolated both operationally (separate account) and
  addressably (non-overlapping `/16` supernet), so a future cross-environment
  peering or Transit Gateway attachment would never require renumbering
  either side.
