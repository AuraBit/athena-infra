# IPAM Allocation

The estate's full address plan across all three environments (CONTEXT.md
D-21, Plan 02-05, Task 1) — every subnet CIDR any `envs/*/core-network`
env root will ever hold, derived from the exact `cidrsubnet()` arithmetic
`modules/core-network/subnets.tf` uses, not restated from memory or typed
by hand.

## The supernet rule

Each environment gets its own `/16` supernet, deliberately non-overlapping:

| Environment | Supernet |
|-------------|----------|
| `dev` | `10.0.0.0/16` |
| `stg` | `10.1.0.0/16` |
| `prod` | `10.2.0.0/16` |

The real reason enterprises do this — and the reason it is worth stating
plainly rather than leaving it implicit — is **peering and transit**: if
two environments' address spaces ever needed a VPC peering connection or a
Transit Gateway attachment between them (a cross-environment shared
service, a break-glass admin path, a migration window), overlapping CIDRs
would make that impossible without first renumbering one of them live.
Choosing non-overlapping supernets up front costs nothing today and removes
an entire category of future migration pain that is expensive and risky to
fix retroactively. Each environment's live account boundary (D-16's
simulated account-per-env) already isolates it operationally; the CIDR plan
additionally isolates it addressably, so the two boundaries reinforce each
other instead of one being an accident of the other.

## How these values were generated

Every subnet below is `cidrsubnet(<supernet>, 4, <index>)` — the identical
call `modules/core-network/subnets.tf`'s `aws_subnet.this` resource makes,
with `subnet_newbits = 4` (the module's own default, turning each `/16`
supernet into `/20` subnets) and `index` computed by that same file's
`cidr_index` local: **tier-major, then AZ** — the three tiers in order
(`public`, `private-app`, `private-data`) each claim three consecutive
indices, one per availability zone in order (`us-east-1a`, `us-east-1b`,
`us-east-1c`). Tier 0 (`public`) takes indices 0–2, tier 1 (`private-app`)
takes 3–5, tier 2 (`private-data`) takes 6–8.

Dev's 9 rows below were confirmed directly against the real, applied stack
via `terraform show -json` in `envs/dev/core-network` (Plan 02-03) — not
merely predicted. Stg's and prod's 18 rows do not have an applied env root
yet (Plan 02-08+ creates them), so their values were computed by evaluating
the exact same `cidrsubnet()` call `terraform console` would run against
those supernets:

```
$ cd envs/dev/core-network
$ terraform console
> cidrsubnet("10.1.0.0/16", 4, 0)   # stg, public, us-east-1a
"10.1.0.0/20"
> cidrsubnet("10.2.0.0/16", 4, 3)   # prod, private-app, us-east-1a
"10.2.48.0/20"
```

Any reader can reproduce every row in the table below the same way: run
`terraform console` from any initialized `envs/*/core-network` directory
(the function is pure — it does not depend on that directory's own applied
state) and call `cidrsubnet("<supernet>", 4, <index>)` for `index` 0
through 8, using the tier/AZ-to-index mapping above.

## Allocation table

| Environment | Tier | Availability Zone | CIDR |
|-------------|------|--------------------|------|
| dev | public | us-east-1a | `10.0.0.0/20` |
| dev | public | us-east-1b | `10.0.16.0/20` |
| dev | public | us-east-1c | `10.0.32.0/20` |
| dev | private-app | us-east-1a | `10.0.48.0/20` |
| dev | private-app | us-east-1b | `10.0.64.0/20` |
| dev | private-app | us-east-1c | `10.0.80.0/20` |
| dev | private-data | us-east-1a | `10.0.96.0/20` |
| dev | private-data | us-east-1b | `10.0.112.0/20` |
| dev | private-data | us-east-1c | `10.0.128.0/20` |
| stg | public | us-east-1a | `10.1.0.0/20` |
| stg | public | us-east-1b | `10.1.16.0/20` |
| stg | public | us-east-1c | `10.1.32.0/20` |
| stg | private-app | us-east-1a | `10.1.48.0/20` |
| stg | private-app | us-east-1b | `10.1.64.0/20` |
| stg | private-app | us-east-1c | `10.1.80.0/20` |
| stg | private-data | us-east-1a | `10.1.96.0/20` |
| stg | private-data | us-east-1b | `10.1.112.0/20` |
| stg | private-data | us-east-1c | `10.1.128.0/20` |
| prod | public | us-east-1a | `10.2.0.0/20` |
| prod | public | us-east-1b | `10.2.16.0/20` |
| prod | public | us-east-1c | `10.2.32.0/20` |
| prod | private-app | us-east-1a | `10.2.48.0/20` |
| prod | private-app | us-east-1b | `10.2.64.0/20` |
| prod | private-app | us-east-1c | `10.2.80.0/20` |
| prod | private-data | us-east-1a | `10.2.96.0/20` |
| prod | private-data | us-east-1b | `10.2.112.0/20` |
| prod | private-data | us-east-1c | `10.2.128.0/20` |

27 subnets total (3 environments × 3 availability zones × 3 tiers), every
CIDR pairwise-disjoint — confirmed programmatically (Python's `ipaddress`
module, every one of the 351 possible pairs checked for overlap; none
found) as part of authoring this document, not merely asserted.

## Reserved and unallocated space

Each `/16` supernet carves out `9 × /20 = 9 × 4,096 = 36,864` addresses for
today's three-tier topology — `9` of the `16` possible `/20` blocks a `/16`
divides into under this `subnet_newbits = 4` scheme (`36,864` of a `/16`'s
`65,536` total addresses). The remaining **7 unallocated `/20` blocks per
environment** (`10.<env>.144.0/20` through `10.<env>.240.0/20` — the
indices 9 through 15 that `cidrsubnet()` never produces for this module's
current 3-tier layout) are free for a future stack to claim without
touching this module's existing subnet layout at all: a fourth tier
(management/bastion, or a dedicated CI/build subnet), additional AZs
beyond the three this module currently spans, or a Phase 6 Data/Storage
stack that wants its own dedicated subnet range rather than sharing
`private-data`. Because every existing subnet's index is fixed by
`cidrsubnet()`'s deterministic arithmetic (tier-major, then AZ), claiming
one of these unused indices for a new purpose is additive — it can never
collide with or renumber a subnet this module already created.
