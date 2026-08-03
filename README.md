<p align="center">
  <img src="docs/assets/athena-logo.svg" alt="Athena logo" width="150">
</p>

<h1 align="center">Athena — Infrastructure</h1>

<p align="center">
  <strong>A production-grade DevOps estate that runs entirely on your laptop — for $0.</strong><br>
  Terraform · Ansible · k3d · Gateway API · LocalStack · GitHub Actions
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/Terraform-1.11%2B-844FBA?logo=terraform&logoColor=white" alt="Terraform 1.11+">
  <img src="https://img.shields.io/badge/Kubernetes-k3d%20v5.9-326CE5?logo=kubernetes&logoColor=white" alt="k3d v5.9">
  <img src="https://img.shields.io/badge/Ansible-core%202.17%2B-EE0000?logo=ansible&logoColor=white" alt="Ansible core 2.17+">
  <img src="https://img.shields.io/badge/LocalStack-AWS%20emulation-4D29B4" alt="LocalStack">
  <img src="https://img.shields.io/badge/PRs-welcome-brightgreen.svg" alt="PRs welcome">
</p>

---

**Athena** is an open replica of the CI/CD pipeline and infrastructure estate that large engineering organisations run in production — built to be **studied, broken, fixed, and explained**. Everything runs locally: k3d stands in for EKS, LocalStack emulates AWS, and `act` plus a self-hosted runner cover CI — so the entire estate costs exactly **$0** to operate.

This repository is the estate's **infrastructure layer**: host bootstrap, dual-cluster topology, wildcard DNS and TLS, AWS emulation, GitHub governance-as-code, and a verification harness that re-proves the whole world from a cold shell in one command.

## The estate at a glance

Athena spans four repositories, each with a single responsibility:

| Repository | Role |
|---|---|
| [`athena-infra`](https://github.com/AuraBit/athena-infra) | **(this repo)** Terraform stacks, Ansible bootstrap, k3d cluster configs, verification harness |
| [`athena-app`](https://github.com/AuraBit/athena-app) | Service monorepo — 11 gRPC/polyglot microservices plus a custom Go media service |
| [`athena-gitops`](https://github.com/AuraBit/athena-gitops) | ArgoCD-watched GitOps manifests — trunk-based, folder-per-environment promotion |
| [`athena-docs`](https://github.com/AuraBit/athena-docs) | Platform handbook — estate-wide ADRs, architecture diagrams, per-tool study notes |

## What lives here

- **Terraform** — a GitHub governance stack managing the `AuraBit` organisation as code (teams, repositories, branch protection, deployment Environments), with AWS lifecycle stacks (Core/Network, Data/Storage, Application/Compute) targeting LocalStack next on the roadmap.
- **Ansible** — deliberately small, host-scoped roles: wildcard DNS for the `athena.net` domain, LocalStack as a managed host service, and an ephemeral just-in-time GitHub Actions runner. One `ansible-playbook ansible/site.yml` run provisions the whole host foundation idempotently.
- **k3d cluster configs** — two declarative clusters (`app` and `platform`) that stand in for EKS, each with a tainted server node mimicking EKS's invisible managed control plane, Envoy Gateway for L7 routing (Gateway API, not the retired ingress-nginx), and cert-manager TLS backed by a locally-trusted mkcert CA.
- **Verification harness** — `scripts/verify.sh` discovers and runs every `verify-*.sh` area check (clusters, DNS/TLS, LocalStack, governance, runner) and never lets one broken area mask the rest. If it exits 0, the estate works.
- **Runbooks and ADRs** — operational procedures ([`docs/runbooks/`](docs/runbooks/)) and the reasoning behind every non-obvious choice ([`docs/adr/`](docs/adr/)).

## Quick start

> **Prerequisites:** a Linux host (the bootstrap script targets Arch Linux) with sudo, a free [LocalStack](https://localstack.cloud) account token in `localstack/.localstack.env`, and — only for the CI-runner step — a GitHub PAT. Steps degrade gracefully; `verify.sh` reports each area independently.

```bash
git clone https://github.com/AuraBit/athena-infra.git && cd athena-infra

# 1. Provision the host toolchain — Docker, k3d, mkcert, Helm v4, act (idempotent)
bash scripts/bootstrap-host.sh

# 2. Create both clusters and install the platform layer
#    (Gateway API CRDs → Envoy Gateway → cert-manager, in that order)
k3d cluster create --config k3d/app-cluster.yaml
k3d cluster create --config k3d/platform-cluster.yaml
bash scripts/install-cluster-platform.sh k3d-app
bash scripts/install-cluster-platform.sh k3d-platform

# 3. Bring up the host foundation: wildcard DNS → LocalStack → CI runner
ansible-galaxy collection install -r ansible/requirements.yml
ansible-playbook ansible/site.yml

# 4. Prove the whole estate end to end
bash scripts/verify.sh
```

See [`docs/cluster-topology.md`](docs/cluster-topology.md) for the full picture of what steps 2–3 build, and [`docs/runbooks/world-rebuild.md`](docs/runbooks/world-rebuild.md) for recovering after a LocalStack restart.

## Repository layout

```
athena-infra/
  scripts/
    bootstrap-host.sh            # idempotent host toolchain provisioning (Docker, k3d, mkcert, Helm v4, act)
    install-cluster-platform.sh  # Gateway API + Envoy Gateway + cert-manager, reused by both clusters
    verify.sh                    # dispatcher: runs every scripts/verify-*.sh in sorted order
    verify-*.sh                  # per-area assertions: skeleton, clusters, LocalStack, governance, runner
  k3d/                           # declarative k3d configs for the app and platform clusters
  ansible/
    site.yml                     # aggregator: DNS → LocalStack → runner, in dependency order
    roles/                       # bootstrap-dns, localstack, runner
  clusters/                      # in-cluster manifests: ClusterIssuer, Gateways, smoke workloads
  localstack/                    # LocalStack compose + service configuration
  governance/                    # Terraform GitHub-governance stack (state kept local — see ADR)
  docs/
    adr/                         # repo-scoped architecture decision records
    runbooks/                    # github-bootstrap, promotion-gating, runner-ops, world-rebuild
```

## Design decisions

Every non-obvious choice is recorded as an ADR — the estate-wide ones live in [`athena-docs`](https://github.com/AuraBit/athena-docs), and this repo keeps its own:

- [ADR-0001 — the dual-cluster k3d shape](docs/adr/0001-k3d-dual-cluster-shape.md) (why two clusters, why tainted servers)
- [ADR-0002 — Envoy Gateway as the Gateway API implementation](docs/adr/0002-envoy-gateway-as-gateway-api-implementation.md)
- [ADR-0003 — local DNS and TLS](docs/adr/0003-local-dns-and-tls.md) (dnsmasq wildcards + mkcert-backed cert-manager)
- [ADR-0004 — LocalStack as a host service](docs/adr/0004-localstack-as-a-host-service.md)
- [ADR-0005 — an ephemeral, just-in-time self-hosted runner](docs/adr/0005-ephemeral-jit-self-hosted-runner.md)

One decision worth calling out here because it surprises people: **Terraform state locality is split on purpose.** The GitHub governance stack keeps local state (it tracks a real, persistent GitHub org that outlives every restart), while the AWS stacks keep state **inside LocalStack S3 itself** — so a LocalStack restart wipes emulated resources and their state *together*, and Terraform never believes something exists that doesn't. Recovery is a documented rebuild runbook, not a backup restore, and that drill is practiced deliberately.

## Project status

Athena is under active development, built in public. **Working today:** dual k3d clusters with Gateway API routing and locally-trusted TLS, wildcard DNS, LocalStack-backed AWS emulation, the GitHub governance stack, an ephemeral self-hosted CI runner with an `act`-based inner loop, and the end-to-end verification harness. **On the roadmap:** the Terraform AWS lifecycle stacks, the microservices workload, ArgoCD-driven GitOps CD with progressive delivery (Argo Rollouts), a full observability stack (Prometheus, Grafana, Loki, Alloy), Vault, and policy-as-code gates (OPA/Conftest, Trivy, Checkov).

## Contributing

Issues and pull requests are welcome — whether it's a broken verify check, a doc gap, or a pattern you'd have built differently. Before proposing structural changes, skim the relevant ADR (or open an issue to discuss adding one); decisions here are documented so they can be challenged with context rather than re-litigated blind.

## License

[MIT](LICENSE) — use anything here freely, in your own labs, interviews, or production estates.
