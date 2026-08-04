# 0011. Estate Tagging Standard

* Status: accepted
* Date: 2026-08-04
* Deciders: Yahia Tarek (YahiaEng)
* Tier: short-form

## Context

CONTEXT.md D-26 requires a machine-enforced tag contract across every AWS
resource this estate's Terraform creates — the enterprise chargeback/
ownership/audit tagging discipline that is easy to promise in a document
and, without a mechanical check, easy to let quietly rot. Phase 6's OPA
policy gate additionally needs a small, stable set of tag names to key its
protected-resource-destroy check on, which makes the tag names decided
here a cross-phase interface, not merely an internal convention this
phase alone consumes.

This ADR deliberately does not restate the tag contract itself — the full
specification (the six mandatory tags, the conditional `Protection` tag,
and exactly how `CKV_ATHENA_1` enforces it) lives in
`docs/tagging-standard.md`. Duplicating that content here would create two
documents that can silently drift from each other the next time one of
them is edited and the other is not; this record exists to state the
decision and its consequences, and to point at the specification rather
than reproduce it.

## Decision

Six mandatory tags (`Project`, `Environment`, `Stack`, `ManagedBy`,
`Owner`, `CostCenter`) are applied through every environment root's AWS
provider `default_tags` block, inherited structurally by every taggable
resource rather than set per-resource. One conditional tag, `Protection`,
is applied per-resource on a deliberately small, curated set (NAT gateways,
the flow-logs bucket) whose destruction is consequential enough to warrant
mandatory human review of any plan touching them. See
`docs/tagging-standard.md` for the full contract, including why
`Protection` is deliberately kept out of `default_tags`.

**Phase 6's OPA policy gate reads the `Protection` tag directly** off
`terraform show -json`'s fully-resolved plan to block any plan containing
a delete or replace action against a tagged resource — making the tag
*name* itself, not just its presence, part of the interface between this
phase and Phase 6's gate. Phase 6 does not re-derive which tag name means
"protected"; it reads the name this phase decided.

The standard is machine-enforced, not merely documented: `checkov/custom/
athena_required_tags.py` (`CKV_ATHENA_1`) is a custom Checkov check, wired
into `.checkov.yaml`, that fails the CI `static` job when a taggable
resource is missing a mandatory tag — proven to fire, not merely present in
the ruleset, per Plan 02-05's own verification.

## Consequences

* Renaming a mandatory tag, or `Protection` specifically, after this point
  means editing every resource in every stack that carries it plus the
  Phase 6 OPA policy that reads it — the tag names are effectively frozen
  from here, and CONTEXT.md D-26 already rates this decision "costly" to
  reverse for exactly that reason.
* A resource type Checkov cannot yet prove `default_tags` reaches (any
  future AWS resource type Phase 6 introduces — RDS, ElastiCache,
  CloudFront, EKS, IAM) is held to the strict explicit-tags standard until
  it is empirically proven and promoted into the trusted-coverage
  allowlist, per `docs/tagging-standard.md`'s own enforcement section —
  new resource types do not get the benefit of the doubt.
* `docs/tagging-standard.md` remains the single source of truth for the
  tag list itself; this ADR is the decision record for *why* it exists and
  *what depends on it*, and the two are expected to stay in sync by
  convention (this ADR changes only if the decision itself changes, not
  every time a tag value is edited).
