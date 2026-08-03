# 0004. LocalStack as a Host Service

* Status: accepted
* Date: 2026-08-03
* Deciders: Yahia Tarek (YahiaEng)
* Tier: short-form

## Context

The estate needs a local AWS account for Terraform verification, at $0.
Conceptually, LocalStack should *be* the AWS account rather than a test
double bolted onto the clusters — it needs to live outside and outlive
either k3d cluster, be reachable from the host/CI/Terraform and from inside
cluster pods, and its tier reality (what's genuinely emulated versus
license-gated) needs to be stated honestly rather than assumed from an
optimistic health check.

## Decision

LocalStack runs as a **host-level docker-compose service under systemd**,
Ansible-provisioned (`bootstrap-localstack` role), reachable at
`localhost:4566` from the host/CI/Terraform and at `host.k3d.internal:4566`
from inside either cluster's pods (the D-15 reachability split — both
publish bindings are `0.0.0.0`, not loopback-only, because k3d resolves
`host.k3d.internal` to the Docker bridge gateway IP, not `127.0.0.1`).

Ephemerality is embraced, not fought: the free Hobby tier's LocalStack
process holds all of its own state in memory/container-local storage, so a
restart wipes it. From Phase 2 onward, Terraform state for the AWS-emulated
stacks lives in LocalStack's own S3 (not local disk), which means a restart
wipes the Terraform state and the resources it describes **together** — a
coherent fresh world, not drift between what Terraform thinks exists and
what's actually running. Recovery is the documented world-rebuild runbook
(`docs/runbooks/world-rebuild.md`), framed as recurring disaster-recovery
practice rather than an incident.

**Tier reality, confirmed live rather than assumed** (`docs/localstack-
service-coverage.md`): the Hobby tier's own `/_localstack/health` endpoint
optimistically lists `rds`, `elasticache`, `cloudfront`, and `eks` as
`"available"` regardless of actual license coverage — a real API call
against each returns a license-gated `InternalFailure` instead. `s3`,
`iam`, and `ec2` are confirmed genuinely emulated by a live round trip.
The LocalStack Open-Source Program application (which would unlock the free
Ultimate tier covering all four gated services) requires a public repo and
an OSI license — both now satisfied — and was deliberately deferred to
after Plan 04's repos went public; its outcome is not yet known. As of
2026-08-03, eligibility remains fully confirmed but submission is still
deliberately deferred, by explicit project-owner decision, until more of the
estate is visibly built out on `github.com/AuraBit` to strengthen the
application's presentation to reviewers — there is no fixed submission date,
and the application has not yet been filed.

## Consequences

* Every Phase 2/6 Terraform stack targeting `s3`/`iam`/`ec2` can rely on
  genuine local verification; anything targeting `rds`/`elasticache`/
  `cloudfront`/`eks` ships as production-grade code with an honest
  code+docs-only divergence statement unless OSS Program approval lands.
* The world-rebuild runbook is not a one-time recovery doc — it is expected
  to run repeatedly across this project's life, which is itself the
  intended DR-practice value (feeding Phase 7's DR-01/DR-02).
* This is a deliberate divergence from the governance stack's state story
  (ADR-0006): GitHub is real and persistent, so its Terraform state stays
  local; the AWS emulation is ephemeral by design, so its Terraform state
  lives where the resources themselves live.
