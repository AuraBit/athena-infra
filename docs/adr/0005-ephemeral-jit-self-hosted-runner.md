# 0005. Ephemeral JIT Self-Hosted Runner on the Host Docker Daemon

* Status: accepted
* Date: 2026-08-03
* Deciders: Yahia Tarek (YahiaEng)
* Tier: full-madr

## Context and Problem Statement

Heavy CI work (Docker BuildKit image builds pushed to the local registry,
and later Terraform apply against LocalStack) needs to run on this specific
local machine, since it is the only place the registry, LocalStack, and the
k3d clusters actually exist. GitHub-hosted runners cannot reach any of
them. The runner must be registered against the estate's org, must not
leak a long-lived credential, must not let a job inherit a previous job's
filesystem state, and must be restricted so it never executes untrusted
(pull-request-triggered) code.

## Decision Drivers

* The requirement fixes the runner to this specific local machine — no
  fleet, no autoscaling target, nothing that could reasonably live in a
  Kubernetes cluster instead of on the host.
* D-16/D-17 already commit to an ephemeral runner using the host Docker
  daemon (not Docker-in-Docker) so BuildKit's layer cache persists across
  ephemeral runner instances, at the cost of an honestly-stated
  root-equivalent exposure (docker-group membership is root-equivalent —
  Docker's own security model treats socket access as full root).
* A registration credential must never be the runner's own long-lived
  auth — GitHub's JIT config API exists specifically to avoid that anti-
  pattern (RESEARCH.md's own explicit warning).
* Self-hosted jobs must never be reachable from a pull-request-triggered
  event — a pwn-request attack surface this project's threat model treats
  as high-severity.

## Considered Options

* **A long-lived registered runner**, authenticated with a persistent
  registration and no per-job rotation.
* **Actions Runner Controller (ARC)**, a Kubernetes-hosted runner fleet.
* **Docker-in-Docker (DinD) isolation** instead of the host Docker daemon.
* **Ephemeral, JIT-configured runner on the host Docker daemon.** (Chosen.)

## Decision Outcome

Chosen option: **"Ephemeral, JIT-configured runner on the host Docker
daemon,"** implemented as a dedicated `athena-runner` systemd service
(`Restart=always`) whose `jitconfig.sh` fetches a fresh, single-use JIT
configuration from GitHub's `generate-jitconfig` API at every start using a
PAT scoped to `manage_runners:org` only — that PAT is used solely to fetch
the JIT config, never as the runner's own credential, and no reusable
registration token is ever written to disk (grep-verified across the
estate's git history and the running unit's journal: zero matches) —
because it is the only option that satisfies every driver above without
contradicting D-16's ephemeral, single-machine design.

### Consequences

* Good, because ephemerality is real, not declared: the runner rotates to
  a fresh registration after every job (observed live: id `6 -> 15 -> 16 ->
  18` across this plan's testing), so no job inherits a previous job's
  filesystem state.
* Good, because BuildKit's layer cache persists in the host daemon across
  every ephemeral runner instance, proven live by a `CACHED` layer on a run
  that started from a brand-new runner registration.
* Good, because the runner is scoped to a dedicated, restricted
  `athena-selfhosted` runner group (not the org's Default group, which
  ships `allows_public_repositories=false` and would silently refuse every
  job from this all-public-repo estate — a live-discovered gap, fixed by
  creating the dedicated group directly via the runner-groups API since the
  `integrations/github` provider has no runner-group resource).
* Bad — and stated honestly, not minimized: the `athena-runner` OS user is
  in the `docker` group, which is root-equivalent on this host. This is the
  accepted cost of D-17's host-Docker-daemon choice, bounded by four
  independent compensating controls documented in `docs/runbooks/
  runner-ops.md`: (1) no PR-family trigger on any self-hosted workflow,
  mechanically asserted by `verify-runner.sh`; (2) a redundant job-level
  `if github.ref == 'refs/heads/main'` condition, also asserted; (3) the
  org-level "require approval for all outside collaborators on fork PRs"
  setting (Plan 05 user_setup — a genuine, permanent manual step with no
  API surface at all, not yet independently re-verified as complete at
  this ADR's writing); (4) the org-wide action allowlist and required
  SHA-pinning (`actions-security.tf`). None of the four alone is
  sufficient; together they are the honest interview answer to "why is it
  safe to run a self-hosted runner against a public repo on a personal
  workstation."
* Bad, because GitHub's org-level runners API never returns the documented
  `ephemeral` field for this org on either the list or detail endpoint
  (confirmed live across dozens of calls) — ephemerality is instead
  asserted from the runner's own local `.runner` file, a workaround
  documented so the next reader doesn't re-discover the gap.

## Pros and Cons of the Options

### A long-lived registered runner

* Good, because it is the simplest possible setup — register once, never
  touch it again.
* Bad, because a persistent registration is a persistent credential and a
  persistent filesystem — a compromised job leaves state a future job can
  inherit, and a stolen registration token doesn't expire on its own.
* Bad, because it directly contradicts D-16's ephemeral-runner requirement
  and this project's stated security posture.

### Actions Runner Controller (ARC)

* Good, because ARC is the correct answer at fleet scale — Kubernetes-
  native scaling, no manual host provisioning per runner, the right
  interview answer for "how would you run this at a real company."
* Bad, because the requirement fixes the runner to this one local
  machine — there is no fleet to autoscale, and running ARC just to manage
  a single always-on runner is complexity with no corresponding benefit
  here.
* Bad, because ARC would strip Ansible of its one scoped role in this
  project (D-16/D-17 assign runner provisioning to Ansible specifically as
  a deliberate, honest demonstration of Ansible's shrunk-but-real modern
  scope) — moving runner lifecycle into Kubernetes manifests would leave
  Ansible with nothing left to do.
* Rejected as build scope, flagged explicitly as a study-notes topic and a
  plausible v2 exploration — the rejection is a scoping decision for this
  project, not a claim that ARC is the wrong tool in general.

### Docker-in-Docker (DinD) isolation

* Good, because it avoids the root-equivalent `docker` group exposure
  entirely — each job's Docker daemon is isolated from the host's.
* Bad, because it loses the host daemon's persistent BuildKit layer cache
  across ephemeral runner instances — every job would rebuild from a cold
  cache, directly contradicting D-17's cache-persistence goal and costing
  real build-speed time on every run.
* Bad, because DinD itself typically requires a privileged container,
  trading one root-equivalent exposure for a different one rather than
  eliminating the risk category.

### Ephemeral, JIT-configured runner on the host Docker daemon (chosen)

* See Decision Outcome and Consequences above.
