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
`emulated`. It is **not yet submitted**: the application requires a public
repository, and this project's repos go public in Plan 04. The application is
tracked as a deferred, non-blocking follow-up to be submitted immediately
after Plan 04 lands — the roadmap does not wait on approval (RESEARCH.md Open
Question 2 records no published approval SLA), exactly as this plan and
CONTEXT.md D-15 already specify.

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
| s3 | Phase 2 IAC-01/IAC-02 (Terraform S3 state backend); Phase 7 DR-01 (Velero backups) | Hobby (free, account + token) | emulated | — |
| iam | Phase 2 IAC-01 (governance-stack roles/policies); Phase 6 IAC-01 (EKS/Karpenter IAM) | Hobby | emulated | — |
| ec2 | Phase 2 IAC-01 (Core/Network stack: VPC, subnets, security groups, IP reservations) | Hobby | emulated | — |
| rds | Phase 6 IAC-01 (Data/Storage stack: Postgres) | Ultimate (paid on Hobby — confirmed live: `describe-db-instances` returns a license-gated `InternalFailure`) | code+docs-only | Terraform for `aws_db_instance` ships production-grade and would apply cleanly against real AWS; against this Hobby-tier account the API is license-gated, so it is never claimed as apply-verified locally. The running app talks to a plain containerized Postgres instead (see README "State locality" and project `.claude/CLAUDE.md`'s Postgres row). Moves to `emulated` if the OSS Program application (submitted after Plan 04) is approved. |
| elasticache | Phase 6 IAC-01 (Data/Storage stack: Redis/Valkey sessions) | Ultimate | code+docs-only | Same license-gated `InternalFailure` confirmed live for `describe-cache-clusters`. The app's session store runs as a plain containerized Valkey instance instead. Same OSS Program approval path as `rds`. |
| cloudfront | Phase 6 IAC-01 (media CDN, `media-<env>.athena.net`) | Ultimate | code+docs-only | Confirmed live: `list-distributions` returns the same license-gated `InternalFailure`. CloudFront's edge-CDN behavior has no meaningful local stand-in regardless of tier (no real edge network to emulate locally) — this row is expected to stay `code+docs-only` even after OSS Program approval, and that expectation is recorded here rather than left implicit. |
| eks | Phase 6 IAC-01/IAC-06 (Application/Compute stack: cluster + node pools) | Ultimate | code+docs-only | Confirmed live: `list-clusters` returns the same license-gated `InternalFailure`. k3d already stands in for the actually-running cluster (CONTEXT.md D-14); this Terraform resource exists to prove the IaC authoring pattern, not to stand up a real control plane locally — the same caveat `.claude/CLAUDE.md` already applies to Karpenter (real EC2 Fleet/Spot APIs have no free local emulation at the fidelity Karpenter's scheduler logic needs), `code+docs-only` regardless of LocalStack tier. |

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
