# athena-infra

Infrastructure repo for the **Athena** production-grade DevOps estate mockup
(interview-prep project — see the platform handbook, `athena-docs`, for the
full estate-level story). This repo owns:

- **Terraform** lifecycle stacks: Core/Network, Data/Storage, Application/Compute
  (Phase 2 / Phase 6), plus the GitHub **governance stack** (Phase 1) managing
  the `AuraBit` org (D-05/D-06; the plan's originally-assumed login
  `athena-platform` was already taken by an unrelated account), teams, repos,
  branch protection, and Environments.
- **Ansible** roles scoped narrowly to host bootstrap and provisioning: the
  `bootstrap-dns` role (wildcard DNS for the `athena.net` domain fiction) and,
  from Phase 6, the self-hosted GitHub Actions runner role.
- **Declarative k3d cluster configs** for the two local Kubernetes clusters
  (`app`, `platform`) that stand in for EKS.
- **Verification scripts** (`scripts/verify.sh` + `scripts/verify-*.sh`) that
  re-prove the whole local estate from a cold shell in one command.

## Directory map

```
athena-infra/
  scripts/
    bootstrap-host.sh            # idempotent host toolchain provisioning (Docker, k3d, mkcert, Helm v4)
    install-cluster-platform.sh  # Gateway API + Envoy Gateway + cert-manager installer, reused by both clusters
    verify.sh                    # dispatcher: runs every scripts/verify-*.sh in sorted order
    verify-skeleton.sh           # Plan 01 assertions: cluster shape, DNS, TLS, the hello.athena.net path
  k3d/
    app-cluster.yaml             # declarative k3d config for the app cluster (Plan 01)
  ansible/
    dns.yml                      # playbook applying the bootstrap-dns role
    roles/bootstrap-dns/         # renders dnsmasq wildcard config for *.athena.net / *.platform.athena.net
  clusters/
    common/
      mkcert-clusterissuer.yaml  # cert-manager ClusterIssuer backed by the mkcert root CA
    app/
      gateway.yaml                # GatewayClass + Gateway + wildcard Certificate for the app cluster
      smoke/hello-echo.yaml       # the one proven request path: Deployment + Service + HTTPRoute
  governance/                     # Terraform GitHub-governance stack (Plan 04) — state kept local, see below
```

## State locality

Two different Terraform state stories live in this repo, and the difference is
deliberate, not an oversight:

- **Governance stack state** (`governance/`) is kept **local** (git-ignored,
  backed up outside git) because it tracks a real, persistent GitHub org that
  outlives every local restart. Losing local state here would mean losing
  track of infrastructure that still exists.
- **Phase 2+ AWS-stack state** (Core/Network, Data/Storage, Application/Compute)
  lives in **LocalStack S3** instead, because LocalStack's free tier is itself
  ephemeral — a restart wipes both the emulated AWS resources and their
  Terraform state *together*, which is the coherent behaviour (no drift
  between "what Terraform thinks exists" and "what's actually running").
  Recovery is a documented world-rebuild runbook, not a backup restore.

## Cluster and DNS shape (Plan 01)

The app cluster (`k3d-app` context) is a 1-server + 3-agent k3d cluster with
the bundled Traefik ingress disabled and the server node tainted
`CriticalAddonsOnly=true:NoExecute`, mimicking EKS's invisible managed control
plane. Envoy Gateway (not ingress-nginx, which is retired) handles L7 routing.
TLS is issued in-cluster by cert-manager from a `ClusterIssuer` backed by the
host's mkcert root CA. Wildcard DNS for `*.athena.net` → `127.0.0.1` (this
cluster) and `*.platform.athena.net` → `127.0.0.2` (the platform cluster,
Plan 02) is rendered by the `bootstrap-dns` Ansible role into
`/etc/dnsmasq.d/athena-wildcards.conf`.

Run `scripts/verify.sh` any time to re-prove the whole skeleton end to end.
