# 0006. CI-06 Trust-Boundary Amendment: Same-Repo-Branch Pull Requests May Reach the Self-Hosted Runner

* Status: accepted
* Date: 2026-08-04
* Deciders: Yahia Tarek (YahiaEng)
* Tier: short-form

## Context

This ADR uses the short-form's three-section shape (Context, Decision,
Consequences — the same shape as ADR-0004), but earns long-form *depth*
within it: it narrows a published security control (CI-06), not a routine
tooling choice, so the reasoning below is deliberately thorough rather than
compressed to fit the tier's usual brevity.

Phase 1's CI-06 control, as shipped in ADR-0005 and enforced by
`heavy-selfhosted.yml`'s trigger list plus its redundant job-level `if:`,
reads "self-hosted jobs run only on push to a protected branch" — no
pull-request-triggered event of any kind ever reaches the self-hosted
runner. That posture defends against exactly one attack: the **pwn-request**.
An outside contributor opens a pull request whose branch lives in a fork
they control. If a self-hosted job ran against that pull request's code —
even just to run `terraform plan` — the contributor's proposed code would
execute on this developer's own workstation, on a runner whose OS user
(`athena-runner`) is a member of the `docker` group, which is
root-equivalent on this host (ADR-0005's own "Bad" consequence, stated
honestly there and repeated here because it is exactly what CI-06 exists to
keep away from untrusted input). That workstation holds the developer's SSH
keys, browser profile, and every other piece of state a compromised process
on it could reach. A pwn-request is not a theoretical risk on a public
repository with a self-hosted runner attached to it — it is one of the
best-documented supply-chain attack classes against exactly this
configuration.

Phase 2 needs `terraform plan` and `terraform apply` to run on this same
self-hosted runner, because only it can reach `localhost:4566`
(D-11 — GitHub-hosted `ubuntu-latest` runners cannot reach a host-local
service at all). D-01 additionally requires `terraform plan` to run **on
pull requests**, before merge, so a human reviewer can see what a change
would do before approving it — this is the entire point of a plan-on-PR
review workflow, and it is also the workflow every regulated enterprise
that manages infrastructure through pull requests actually runs (Atlantis,
`terraform-plan`-comment-bot patterns, and this project's own D-02 sticky
PR comment all assume a plan job that runs on the PR, not only after
merge). Phase 1's CI-06 wording, taken literally, makes this impossible:
"protected-branch pushes only" means no `terraform plan` can ever run on a
pull request, full stop — because every pull request event is, by
definition, not a push to `main`.

The amendment this ADR records narrows CI-06's wording from
"protected-branch pushes only" to "trusted contexts only." The question
this Context section has to answer honestly is: does that narrowing
actually reopen the pwn-request risk CI-06 exists to close, or does it
close a *different*, disjoint gap that the pwn-request threat model was
never actually protecting against in the first place?

**The argument, stated in threat-model terms, not convenience terms:**
the pwn-request attack is **fork-specific**. It requires the proposed code
to have been written by someone who does *not* already have write access to
this repository — that is what makes it "untrusted." A pull request whose
head branch lives in *this same repository* (`AuraBit/athena-infra`, not a
fork) can only exist if someone pushed that branch here, and pushing a
branch to this repository requires write access to this repository. Anyone
who already holds write access to this repository can, under the Phase 1
posture that predates this amendment, push directly to `main` and trigger
`heavy-selfhosted.yml`'s `push`-triggered self-hosted job immediately — no
pull request, no review, no waiting. That is already true today, before
this amendment exists. So admitting same-repo-branch pull requests to the
self-hosted runner does not add a single new principal to the set of people
who can get code to execute on this runner. Every person who could reach
the runner before this amendment can still reach it, exactly the same way,
with or without this amendment existing. What the amendment changes is
**when** a same-repo contributor's code can reach the runner — one pull
request earlier in the lifecycle than a bare push to `main` — not **who**
can make it reach the runner. A control that restricts *when* a trusted
principal's own code executes, without restricting *who* that principal is,
is not the same control as CI-06, and narrowing it to match what CI-06 was
actually protecting against is not the same thing as weakening it.

Fork pull requests are the disjoint case this amendment does not touch.
Someone with no write access to this repository, proposing code from a
fork they control, is exactly the untrusted-author case CI-06 exists for —
and the amended guard leaves that case exactly as blocked as it was under
the original wording. The guard expression that enforces the boundary,
evaluated per job on every pull-request-triggered self-hosted job in this
workflow:

```yaml
if: github.event.pull_request.head.repo.full_name == github.repository
```

`github.event.pull_request.head.repo.full_name` is the full `owner/repo`
name of the repository the pull request's branch actually lives in.
`github.repository` is this workflow's own repository
(`AuraBit/athena-infra`). These two values are equal only when the pull
request's branch lives in this repository — i.e., same-repo-branch. A fork
pull request's `head.repo.full_name` is the fork's own `owner/repo` (e.g.
`someoutsider/athena-infra`), which never equals `github.repository`, so
the condition evaluates `false` and the job does not run. This is a single
boolean condition, not a network boundary or an approval gate — it is
exactly as strong as GitHub's own reporting of `head.repo.full_name`, which
is why the compensating controls below exist independently of it.

## Decision

Amend CI-06 from "self-hosted jobs run only on push to a protected branch"
to "self-hosted jobs run only in trusted contexts" — where a trusted
context is (a) a push to `main` (unchanged from the original wording), or
(b) a pull request whose head branch lives in this same repository, gated
per-job by `github.event.pull_request.head.repo.full_name ==
github.repository`.

What genuinely does change, stated plainly:

* **The guard is evaluated per job**, on the specific jobs in
  `terraform-core-network.yml` that need `localhost:4566` and therefore
  must run on the self-hosted runner while triggered by a pull request
  (the `plan` job). Static jobs (`static`) run on `ubuntu-latest` and never
  touch this guard at all — they need no self-hosted access regardless of
  trigger (D-11).
* `heavy-selfhosted.yml` is **not** amended — its own trigger list stays
  `push`-and-`workflow_dispatch`-only, deliberately. That workflow builds
  and pushes container images; nothing about this ADR's reasoning changes
  the calculus for that workflow, and narrowing CI-06 estate-wide would be
  a broader change than this specific, load-bearing need justifies. This
  amendment is scoped to the jobs that actually require it.
* **The org-level fork-approval policy remains a second, independent
  control** (Plan 05 user_setup — "require approval for all outside
  collaborators" on this repo's Settings → Actions → General page). That
  setting governs whether a fork pull request's workflow run executes *at
  all*; this ADR's guard governs, independently, whether a workflow run
  that IS executing can reach the self-hosted label set specifically. The
  two controls do not depend on each other, which is the point — either
  one alone being misconfigured does not silently disable the other.
* **The runner stays ephemeral** (ADR-0005) — a same-repo pull request's
  `plan` job runs on a JIT-registered, single-use runner instance exactly
  like every other job today, and GitHub deregisters it the moment the job
  completes. Nothing about this amendment persists any state across jobs
  that didn't already persist (or fail to persist) before it.

**Residual risk, named honestly rather than minimized:** a compromised
collaborator account, or a malicious commit pushed by a legitimate
collaborator, now reaches self-hosted execution one job earlier in the
lifecycle than before this amendment — at pull-request-open time instead
of only at merge-to-`main` time. This is a real, if narrow, change to the
attack timeline for an already-trusted principal, and it is accepted at
this estate's stated ASVS Level 1 posture (`.planning/config.json`'s
`security_asvs_level: 1`) for the same reason Phase 1 accepted the
`docker`-group-membership root-equivalence in the first place: the
alternative — no plan-on-PR review at all — is a strictly worse security
posture for a project whose entire premise is that infrastructure changes
get reviewed *before* they apply, not only audited after the fact.

**Rejected alternative: keep push-only self-hosted triggers.** Retaining
CI-06's original literal wording (no pull-request-triggered event ever
reaches self-hosted, full stop) was considered and rejected. Under that
posture, `terraform plan` could never run on a pull request for any
environment, for any contributor, trusted or not — because D-11 requires
`localhost:4566` reachability for `plan`, and only the self-hosted runner
has it. That would make D-01's entire review model ("plan on PR, apply on
merge") structurally impossible to build: a human reviewer approving a
pull request with no plan output to review is not a meaningful review, it
is a rubber stamp. The push-only alternative optimizes for a security
posture this project does not actually need (zero same-repo pull-request
execution) at the direct cost of a review workflow this project's own
CONTEXT.md decisions (D-01, D-02) explicitly require. It was rejected on
those grounds, not because the pwn-request risk it defends against is
unreal — that risk is real, and remains fully defended against for the
only case it was ever meant to cover: forks.

## Consequences

* Good, because `terraform plan` can now run on pull requests touching
  `envs/*/core-network/**`, which is the precondition for D-02's sticky
  per-environment plan comment and for any meaningful human review of a
  Terraform change before it applies.
* Good, because the amendment is provably scoped — a single, auditable
  boolean guard expression, asserted per job, not a broader relaxation of
  the runner's trust boundary. A future workflow that adds a
  pull-request-triggered self-hosted job without this guard is a
  reviewable diff against a known-good pattern, not a silent regression.
* Good, because the set of people who can reach the self-hosted runner is
  provably unchanged: same-repo write access was always sufficient to
  reach it (via a direct push to `main`) before this amendment existed.
* Bad, and stated honestly: the attack **timeline** for an already-trusted
  principal (a compromised collaborator account, or a malicious commit
  from a legitimate collaborator) is compressed by one step — pull-request
  time instead of only merge time. This is the real cost of this
  amendment, not zero, and it is accepted at ASVS L1 for the reasons given
  above.
* Bad, because `github.event.pull_request.head.repo.full_name ==
  github.repository` is exactly as trustworthy as GitHub's own reporting
  of a pull request's head repository — this ADR does not independently
  verify that field, it relies on GitHub's platform to report it
  correctly, the same trust GitHub Actions' entire trigger-condition model
  already rests on everywhere else in this estate.
* Neutral, because `heavy-selfhosted.yml` is unchanged — its own inline
  commentary already correctly describes push-and-dispatch-only triggers
  for that workflow specifically, and nothing in this ADR's reasoning
  requires touching it. A future ADR would be needed if that workflow ever
  needed the same amendment, and it would need its own justification for
  why — this ADR's reasoning is scoped to jobs that need pull-request-time
  `localhost:4566` access, which `heavy-selfhosted.yml`'s jobs do not.
</content>
