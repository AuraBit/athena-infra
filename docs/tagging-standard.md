# Estate Tagging Standard

The estate-wide tag contract every AWS resource Terraform creates must satisfy
(CONTEXT.md D-26, Plan 02-05, Task 1). This is the machine-enforced version of
a promise every enterprise makes and few actually keep: a tag standard nobody
checks is a document, not a control. `checkov/custom/athena_required_tags.py`
(check id `CKV_ATHENA_1`) is what turns this from prose into a CI gate — see
"How this is enforced" below.

## Where the six mandatory tags come from

Every env root's `provider.tf` sets these six tags once, in the AWS
provider's `default_tags` block (see `envs/dev/core-network/provider.tf`),
not per-resource. The AWS provider merges `default_tags` into every resource
type that has a `tags` schema attribute, whether or not that resource
declares its own explicit `tags` block — this is why almost none of the
resources in `modules/core-network/*.tf` set these six keys directly; they
inherit them structurally, the same way every resource in this estate always
will.

| Tag | Value | Who consumes it and why |
|-----|-------|--------------------------|
| `Project` | always `athena` | Identifies estate ownership at a glance; the one constant across every resource this whole project ever creates. |
| `Environment` | `dev`, `stg`, or `prod` | The same value CI's env-detection matrix (`terraform-core-network.yml`) and the per-env state-bucket naming (`athena-tfstate-<env>`) both key on — this tag is that same partition made visible on the resource itself. |
| `Stack` | which lifecycle stack owns the resource (e.g. `core-network`) | Phase 6's Data/Storage and Application/Compute stacks are separate Terraform state, separate CI workflows, separate applies — a reader (or a remote-state consumer) looking at a tagged resource needs to know which stack's code produced it without guessing from the resource name alone. |
| `ManagedBy` | always `terraform` | Its entire purpose is to make a hand-created resource visibly anomalous. Nothing in this estate is ever created by hand in the AWS console (there is no console — LocalStack has none), but the tag is the same one real AWS accounts use to catch console/CLI drift against Terraform-managed infrastructure, and it costs nothing to carry here too. |
| `Owner` | the responsible team (`platform`) | The chargeback-adjacent "who do we page" tag — matters for on-call routing more than for cost, but travels on the same tag set because enterprises track both together. |
| `CostCenter` | the chargeback dimension (`athena-platform`) | Matters even at $0 real spend, because the discipline of tagging for chargeback is itself the thing that transfers to a real job — an engineer who has never had to think about cost allocation tags will be visibly behind one who has, in an interview or on day one. |

## The seventh, conditional tag: `Protection`

`Protection` is applied **per-resource**, never through `default_tags` — it
marks a resource whose destruction is consequential enough that a plan
containing a delete or replace action against it should never merge without
a human looking at it first.

**Phase 6's OPA policy gate consumes this tag directly**: it inspects
`terraform show -json`'s fully-resolved plan (module outputs, provider
defaults, and `merge()` calls already evaluated — unlike Checkov's static HCL
view, which cannot see any of that) and blocks any plan whose JSON contains a
`delete` or `create_before_destroy`/`replace` action against a resource
carrying `Protection`. **This document is the interface between the two
phases** — Phase 6 does not re-derive which tag name means "protected"; it
reads the name decided here. Renaming this tag later means editing every
resource that carries it and the OPA policy that reads it, which is why
CONTEXT.md D-26 rates this decision "costly" to reverse.

### Which resources carry it, and why

- **NAT gateways** (`modules/core-network/nat.tf`) — destroying one silently
  removes private-app egress for every subnet in its AZ (or, under
  `single_nat_gateway = true`, for every AZ at once). A NAT gateway is the
  kind of resource that is easy to destroy by accident (it looks, in a plan
  diff, like "just an EIP and a gateway") and expensive in blast radius when
  it happens for real.
- **The flow-logs bucket** (`athena-flowlogs-<environment>`,
  `modules/core-network/flow-logs.tf`) — destroying it destroys audit
  evidence. A flow-logs bucket that can be silently deleted by an
  unreviewed plan defeats the entire point of having flow logs: the audit
  trail is only as trustworthy as its own resistance to deletion.

### Why `Protection` is deliberately NOT in `default_tags`

Tagging every resource `Protection = "true"` through `default_tags` would
make the OPA gate fire on every single plan that touches this stack — adding
a subnet, renaming a route table, bumping a module version all produce a
`replace` or `delete` somewhere in a real Terraform plan sooner or later.
A control that blocks that often stops being read and starts being
routed around: the first engineer who hits it three times in a week adds a
blanket bypass, and from that point on the control exists in name only. A
tag that names a genuinely small, deliberately curated set of resources
(two, today) stays credible precisely because it is rare enough that seeing
it in a plan diff is itself a signal worth pausing on.

## How this is enforced

`checkov/custom/athena_required_tags.py` (`CKV_ATHENA_1`) is a Checkov
custom check, wired into `.checkov.yaml` via `external-checks-dir`, that
fails the CI `static` job when a taggable resource in this repository is
missing a mandatory tag it should carry. See that file's own docstring for
exactly how it resolves resources tagged through `default_tags` (which
Checkov, being a static HCL analyzer, cannot see or evaluate) versus
resources whose tags it can directly inspect — the short version is a
documented, provably-correct allowlist of resource types this repo has
verified `default_tags` actually reaches, rather than either trusting every
resource blindly or flagging every resource as non-compliant because the
provider default is invisible to static analysis.

`Protection` is deliberately **not** enforced by this Checkov check — a
static analyzer cannot see whether Phase 6's OPA policy would actually block
a given plan, and trying to approximate that here would either produce false
confidence or false alarms. `Protection` presence is Phase 6's own concern,
checked against the fully-resolved plan JSON where it can be evaluated
correctly.
