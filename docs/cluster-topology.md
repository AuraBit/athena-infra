# Cluster Topology

Two k3d clusters run simultaneously on this host, standing in for the two
EKS clusters PROJECT.md's platform/app split requires (FOUND-01). Each is
declared in `k3d/<name>-cluster.yaml`, uses the identical `rancher/k3s`
image tag (same Kubernetes minor on both), the same tainted-server /
untainted-agent shape, and its own dedicated loopback address so both serve
clean `https://<host>` URLs on port 443 with no port suffix and no
collision (D-12).

| | `app` cluster | `platform` cluster |
|---|---|---|
| k3d context | `k3d-app` | `k3d-platform` |
| Nodes | 1 tainted server + 3 agents | 1 tainted server + 2 agents |
| Loopback | `127.0.0.1` | `127.0.0.2` |
| Domain | `*.athena.net` | `*.platform.athena.net` |
| Registry | `athena-registry` (creates it) | `athena-registry` (attaches via `registries.use`) |

## What runs where

**Platform cluster** hosts the tooling layer — everything that operates
*on* the estate rather than being part of the Athena product:

- ArgoCD (Phase 3+) — GitOps CD, pulling from `athena-gitops`
- Prometheus, Alertmanager, Grafana, Loki, Alloy (Phase 4) — the full
  observability stack, including the Argo Rollouts AnalysisTemplates that
  consume Prometheus metrics for automated canary/blue-green analysis
- HashiCorp Vault (Phase 5) — secrets management, rotation-aware patterns
- SonarQube (Phase 2/3 CI gate) — static analysis, queried by CI, but the
  server itself is workload infrastructure and belongs here, not on `app`

**App cluster** hosts the Athena product itself, split into `dev`, `stg`,
and `prod` namespaces (Plan 02, Task 2; FOUND-01):

- The rebranded Online Boutique fork ("Athena")
- The custom Go "media" service (Postgres, S3-via-CloudFront-fiction,
  Valkey-backed sessions)

This split is organisational and scheduling, not a security boundary — see
"How this diverges from EKS" below and T-01-09 in this plan's threat
register: both clusters share one Docker network, one kernel, and the same
mkcert CA material. Nothing in this estate treats platform/app isolation as
a trust boundary.

## Why the server nodes are tainted

Both clusters taint their single server node with
`CriticalAddonsOnly=true:NoExecute` and disable k3s's bundled Traefik in the
same create invocation (RESEARCH.md Pitfall 1 — tainting after the fact
hangs forever waiting on an untolerated Traefik pod). This mimics EKS's
managed control plane: on real EKS, the control plane is invisible
infrastructure you never schedule workloads onto and never even see as a
node. Tainting the k3d server node forces every workload — smoke tests,
ArgoCD, Prometheus, the Athena app itself — onto agent nodes only, the same
scheduling discipline a real EKS cluster enforces structurally.

## Why multi-node now, not later

Both clusters are multi-node (not single-node) from this plan onward
because later phases silently require at least two schedulable workers per
cluster to demonstrate real behaviour, not simulate it on a single node
that would trivially "pass" any test:

- **Phase 4** — PodDisruptionBudget and node-drain drills need a second
  node to drain *to*; a single-agent cluster can't demonstrate a workload
  surviving a drain.
- **Phase 7** — topology-spread-constraint drills need multiple schedulable
  nodes to show pods actually spreading, not just being told to.

Standing up the correct node count now avoids re-provisioning either
cluster mid-phase later.

## How this diverges from EKS

This is the honest caveat this estate's interview value depends on:
**multi-node k3d here simulates scheduling topology, not failure
isolation.** Every "node" in both clusters is a container on this one
host, sharing this one host's kernel, Docker daemon, and physical
resources. A real EKS worker-node failure — a whole EC2 instance going
down, taking its kernel, its local disk, and every container on it with
it — has no equivalent here: killing a k3d agent container kills a
containerd process on a host that is otherwise completely healthy, and the
"blast radius" reasoning that applies to real AZ/instance failure does not
transfer.

What *does* transfer, faithfully: pod scheduling decisions (taints,
tolerations, affinity, topology spread), how the Kubernetes API server and
controllers behave under `kubectl drain`, how a PodDisruptionBudget blocks
an eviction, how Argo Rollouts' canary/blue-green steps move traffic
between ReplicaSets, and how ArgoCD/GitOps reconciliation works end to end.
Any interview answer, ADR, or study note derived from a drill run against
these clusters must say "this proves scheduling behaviour, not failure
isolation" rather than implying node-loss resilience was actually tested —
overstating that fidelity is the one framing this document exists to
prevent.

## Registry

One `athena-registry` k3d-managed container serves both clusters and the
host — see `scripts/registry-smoke.sh` (Plan 02, Task 2) for the proof and
the exact host-side push target / in-cluster pull reference strings that
Phase 3's CI and Kustomize image fields consume.
