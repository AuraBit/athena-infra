# LocalStack Service Coverage

Per-service **verification mode** for every AWS service this project's roadmap
depends on (Plan 03, Task 3; FOUND-02). This is the primary, machine-checked
record of what is genuinely proven against a running emulator versus what
ships as production-grade Terraform with an honest, written divergence
statement. `scripts/verify-localstack.sh` parses this exact table (same
column headers, same `emulated` / `code+docs-only` vocabulary) and fails if a
row claims emulation the running LocalStack account does not actually
provide — the document and its checker are one contract, not two things that
can silently drift apart.

## Tier reality

LocalStack's free **Hobby** tier has required an account and an
`LOCALSTACK_AUTH_TOKEN` to start the unified `localstack/localstack` image
meaningfully since 2026-03-23 (RESEARCH.md Pitfall 4) — this project has that
account and token (Plan 03, Task 1). The Hobby tier does **not** include RDS,
ElastiCache, CloudFront, or EKS. Confirmed live against this exact account,
not assumed: the LocalStack `/_localstack/health` endpoint lists every one of
these four services as `"available"` regardless of tier — that optimism is
itself the trap RESEARCH.md's Pitfall 4 and this plan's threat model (T-01-13,
fake-success from an un-emulated service) exist to guard against. A real API
call tells the truth instead:

```
$ aws --endpoint-url http://localhost:4566 rds describe-db-instances
An error occurred (InternalFailure) when calling the DescribeDBInstances
operation: Sorry, the rds service is not included within your LocalStack
license, but is available in an upgraded license.
```

The same license-gated `InternalFailure` was confirmed live for
`elasticache describe-cache-clusters`, `cloudfront list-distributions`, and
`eks list-clusters`. S3, IAM, and EC2 (VPC/networking) were confirmed live to
genuinely work — bucket create/list/delete, `iam list-roles`, and
`ec2 describe-vpcs` all returned real, correct responses on this Hobby-tier
account.

The **LocalStack Open-Source Program** application (public repo, non-commercial
use, OSI licence — this project qualifies) would upgrade the account to the
free **Ultimate** tier and move the four `code+docs-only` rows below to
`emulated`. It is **not yet submitted**. The eligibility precondition — four
public, MIT-licensed repos under `github.com/AuraBit` — was independently
re-confirmed live (`gh repo view` on all four, plus a `LICENSE` first-line
check) and is fully met; nothing technical blocks submission. As of
**2026-08-03**, submission is **deliberately deferred by explicit
project-owner decision**, not by any unmet precondition: the reasoning is that
a reviewer sees a stronger, more substantial project the more of the estate is
visibly built out on `github.com/AuraBit` before the form is filed, so the
project owner chose to wait rather than file at the earliest technically
possible moment. There is no fixed trigger date — the trigger is "enough of
the estate visibly built out on GitHub," assessed by the project owner, not a
calendar date or a specific plan number. The roadmap does not wait on approval
regardless (RESEARCH.md Open Question 2 records no published approval SLA);
this deferral only delays when that clock starts, which remains an open,
tracked item (see STATE.md Blockers/Concerns).

**How to update this table when approval lands:** re-run
`scripts/verify-localstack.sh` after upgrading the account — its coverage-table
check will start seeing `rds`, `elasticache`, `cloudfront`, and `eks` as
genuinely callable (not just `"available"` in the health map) once the
license upgrade is live. At that point, flip each row's Verification mode
from `code+docs-only` to `emulated`, replace its Divergence note with `—`,
and re-run the script to confirm it still passes. No other document changes
are required — Phase 6 branches its Terraform verification strategy on
exactly these four values (see this file's `<output>` record in
`01-03-SUMMARY.md`).

## Coverage table

| Service | Consumer (phase / requirement) | LocalStack tier required | Verification mode | Divergence note |
|---|---|---|---|---|
| s3 | Phase 2 IAC-01/IAC-02 (Terraform S3 state backend, proven under real concurrent-apply conditions — see "Phase 2 verification depth" below); Phase 3 APP-03/D-07 (media bucket `athena-media-{dev,stg,prod}`, applied + round-trip-verified via `verify-data-storage.sh`, and the media service's live upload/fetch path); Phase 7 DR-01 (Velero backups) | Hobby (free, account + token) | emulated | — |
| iam | Phase 2 IAC-01 (governance-stack roles/policies); Phase 6 IAC-01 (EKS/Karpenter IAM) | Hobby | emulated | — |
| ec2 | Phase 2 IAC-01/IAC-03 (Core/Network stack: full VPC/subnet/NAT/route/endpoint/security-group/flow-log resource set, live across three simulated accounts — see "Phase 2 verification depth" below) | Hobby | emulated | — |
| rds | Phase 6 IAC-01 (Data/Storage stack: Postgres) | Ultimate (paid on Hobby — confirmed live: `describe-db-instances` returns a license-gated `InternalFailure`) | code+docs-only | Terraform for `aws_db_instance` ships production-grade and would apply cleanly against real AWS; against this Hobby-tier account the API is license-gated, so it is never claimed as apply-verified locally. The running app talks to a plain containerized Postgres instead (see README "State locality" and project `.claude/CLAUDE.md`'s Postgres row). Moves to `emulated` if the OSS Program application — deliberately deferred as of 2026-08-03 pending a more built-out public estate, not yet submitted (see "Tier reality" above) — is later submitted and approved. |
| elasticache | Phase 6 IAC-01 (Data/Storage stack: Redis/Valkey sessions) | Ultimate | code+docs-only | Same license-gated `InternalFailure` confirmed live for `describe-cache-clusters`. The app's session store runs as a plain containerized Valkey instance instead. Same OSS Program approval path as `rds`. |
| cloudfront | Phase 6 IAC-01 (media CDN, `media-<env>.athena.net`) | Ultimate | code+docs-only | Confirmed live: `list-distributions` returns the same license-gated `InternalFailure`. CloudFront's edge-CDN behavior has no meaningful local stand-in regardless of tier (no real edge network to emulate locally) — this row is expected to stay `code+docs-only` even after OSS Program approval, and that expectation is recorded here rather than left implicit. |
| eks | Phase 6 IAC-01/IAC-06 (Application/Compute stack: cluster + node pools) | Ultimate | code+docs-only | Confirmed live: `list-clusters` returns the same license-gated `InternalFailure`. k3d already stands in for the actually-running cluster (CONTEXT.md D-14); this Terraform resource exists to prove the IaC authoring pattern, not to stand up a real control plane locally — the same caveat `.claude/CLAUDE.md` already applies to Karpenter (real EC2 Fleet/Spot APIs have no free local emulation at the fidelity Karpenter's scheduler logic needs), `code+docs-only` regardless of LocalStack tier. |

## Phase 2 verification depth (Core/Network)

Plan 03's `ec2`/`s3` rows above were originally recorded genuinely emulated
on the basis of a single `describe-vpcs` and a single S3 round trip.
Phase 2 (`docs/adr/0004` through `0011`) exercised both services far
harder, against the real Core/Network resource set, and every one of the
following was proven by a live `describe`/`get`/`head` call — not inferred
from `terraform apply`'s own exit code (`scripts/verify-network.sh`,
25 checks):

- **`ec2`**: VPCs, subnets across all three availability zones, internet
  and NAT gateways (including per-AZ placement under
  `single_nat_gateway = false`), route tables and their associations
  (including the `public_route_table_id`'s own `0.0.0.0/0`-to-IGW route,
  Plan 02-10's own closed coverage gap), a gateway VPC endpoint, and
  security groups including default-security-group adoption/lockdown.
- **`s3`**: bucket create/put/get/delete round trips as before, plus —
  this phase's single open technical risk, now settled by observation —
  **S3 conditional writes (`If-None-Match`) genuinely backing Terraform's
  native `use_lockfile = true` state locking** through a real acquire /
  contention / release cycle (`scripts/verify-tfstate-locking.sh`, Plan
  02-01) and under real concurrent CI applies (the concurrency-queue
  drill, `docs/drills/concurrency-queue.md`). RESEARCH.md's Open Question 1
  flagged this as unconfirmed by any source found during research; it is
  no longer an open question.

**No LocalStack fidelity shortfall was found for any Core/Network resource
class this phase exercised.** Every resource in the list above applied and
verified cleanly against the running Hobby-tier account across all three
promotion cycles (dev, stg, prod) — the `ec2`/`s3` rows' Divergence note
stays `—` on that basis, recorded here explicitly rather than left for a
reader to assume no gap was looked for.

**Account-per-environment finding**: `docs/adr/0009-simulated-account-per-environment-and-state-bucket-per-account.md`
records the full decision; the coverage-relevant fact is that LocalStack's
account-per-access-key-ID namespacing (D-16) genuinely worked on the free
Hobby tier — confirmed live under each environment's own credentials via
`sts get-caller-identity` (correct account ID), `s3 ls` (no
cross-environment bucket visibility), and `ec2 describe-vpcs` (each
environment's own `/16` supernet visible in exactly one account, no
other). The documented single-account-with-tag-separation fallback
(CONTEXT.md D-16) was not needed. One honest wrinkle: LocalStack seeds an
identical default VPC (`172.31.0.0/16`) under every simulated account —
its own scaffolding, not Athena-managed, and not cross-environment
leakage of anything this project created.

**Second honest wrinkle, found live in Plan 03-02**: the account boundary
above is an *enumeration* boundary, not a per-resource *authorization*
boundary, and the two are not the same guarantee. `s3 ls` under stg's
credentials correctly omits dev's `athena-media-dev` bucket — confirmed
again for this plan's own bucket, not just core-network's. But a
*direct-addressed* call naming that bucket explicitly (`s3api head-bucket
--bucket athena-media-dev`, `s3api get-bucket-tagging --bucket
athena-media-dev`) under stg's simulated credentials **succeeds**, not
fails — LocalStack's Hobby-tier S3 emulation does not enforce
cross-account IAM authorization for resource-addressed calls, only for
listing. This mirrors real AWS's own S3 namespace shape more than it
first appears (S3 bucket names are genuinely global across all AWS
accounts, not per-account, unlike a VPC id) but real AWS still returns
`403 Forbidden` for a direct call against a bucket your IAM principal has
no policy grant on; LocalStack's Hobby tier does not evaluate bucket
policies/IAM at all, so every direct call the *namespace* permits also
*succeeds*, regardless of caller account. `ec2 describe-vpcs` has no
equivalent gap (VPC ids are account-scoped resource identifiers, not a
global namespace, and LocalStack's EC2 emulation genuinely partitions
them per simulated account). This is a real LocalStack fidelity
limitation, not a defect in this project's Terraform: `modules/data-storage`'s
bucket already carries the production-shaped controls (versioning, SSE,
all-four public-access-block settings, the `Protection` tag) that would
matter against real AWS's own IAM enforcement — see the STRIDE register's
`T-03-10` (accept) in `03-02-PLAN.md` for the disposition this finding
confirms rather than contradicts.

## Where state lives, and why

Two different Terraform state stories exist across this project, and the
difference is deliberate (CONTEXT.md D-10 vs. D-15 — flagged as ADR material
for Plan 07):

- **The Phase 1 governance stack** (`governance/`, Plan 04) keeps its state in
  a **local file**, git-ignored and backed up outside git, because it tracks
  a real, persistent GitHub org that outlives every local restart. Losing
  local state here would mean losing track of infrastructure that still
  exists — the opposite of the ephemerality this section otherwise describes.
- **Every Phase 2+ AWS stack** (Core/Network, Data/Storage,
  Application/Compute) keeps its state in **LocalStack S3** instead,
  deliberately, because a LocalStack restart wipes the free-tier account's
  data. If Terraform state lived anywhere else, a restart would leave state
  describing resources that no longer exist — drift. Keeping state *inside*
  the same ephemeral account means a restart wipes state and resources
  **together**, into one coherent fresh world, not two disagreeing ones.
  Recovery from that restart is a documented runbook
  (`docs/runbooks/world-rebuild.md`), not a backup restore — and it is
  recurring DR practice (Phase 7 DR-01/DR-02 build on the same drill), not a
  failure mode to be avoided.
