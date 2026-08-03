# 0001. k3d Dual-Cluster Shape

* Status: accepted
* Date: 2026-08-03
* Deciders: Yahia Tarek (YahiaEng)
* Tier: full-madr

## Context and Problem Statement

The estate needs two local Kubernetes clusters standing in for EKS: an
`app` cluster carrying the dev/stg/prod Athena workloads, and a `platform`
cluster carrying tooling (ArgoCD, the observability stack, Vault,
SonarQube). Both must run simultaneously and continuously on one host, at
$0, while still teaching real EKS-relevant behaviour — pod scheduling,
`kubectl drain`, PodDisruptionBudget enforcement, topology-spread
constraints, Argo Rollouts traffic shifting — rather than a toy single-node
demo that trivially "passes" every test without exercising any of it.

## Decision Drivers

* Two local clusters run *simultaneously and continuously* during study
  sessions — steady-state resource footprint on a 64GB host matters more
  than any single benchmark number.
* Later phases (4, 7) need real node-drain and topology-spread behaviour,
  which requires at least two schedulable workers per cluster from day one
  — re-provisioning a cluster mid-phase to add nodes is wasted work.
* EKS's control plane is invisible managed infrastructure you never
  schedule workloads onto — the local stand-in should mimic that scheduling
  discipline, not just approximate node count.
* The chosen Kubernetes distribution should track a Kubernetes minor
  version EKS actually supports, so behaviour observed locally transfers to
  a real EKS conversation.
* The failure-isolation story must be stated honestly: every "node" in a
  local Docker-backed cluster shares the host's one kernel, unlike a real
  EKS worker node's separate underlying EC2 instance.

## Considered Options

* **kind** for both clusters.
* **k3d** for both clusters. (Chosen.)
* **A single cluster with namespace separation** instead of two clusters
  (platform tooling and app workloads as namespaces on one cluster).

## Decision Outcome

Chosen option: **"k3d for both clusters,"** sized `app = 1 tainted server +
3 agents` and `platform = 1 tainted server + 2 agents`, k3s pinned to
`v1.35.5-k3s1` (checked against AWS EKS's standard-support version list at
execution time, not defaulted to k3d's newest bundled image) — because it
gives the lowest steady-state footprint for two clusters run continuously,
its built-in local registry and LoadBalancer remove scripting k3d would
otherwise avoid, and it still runs upstream-conformant Kubernetes
underneath (via k3s), so kubectl/Helm/ArgoCD behaviour transfers to real
EKS knowledge without loss.

### Consequences

* Good, because k3d's `--registry-create` and built-in `servicelb` remove
  two categories of manual scripting that kind requires (registry
  containerd-patching, LoadBalancer emulation).
* Good, because the tainted-server / untainted-agent shape mimics EKS's
  invisible managed control plane, forcing every workload — smoke tests,
  ArgoCD, Prometheus, the Athena app itself — onto agent nodes only, the
  same scheduling discipline a real EKS cluster enforces structurally.
* Good, because both clusters being multi-node from day one avoids
  re-provisioning mid-phase when Phase 4/7's drain and topology-spread
  drills arrive.
* Bad, because k3s strips some controllers and uses SQLite by default
  instead of etcd — irrelevant to this project's GitOps/CI/observability
  focus, but a real gap if a future phase's learning goal became etcd or
  control-plane-component depth specifically (documented as the trigger to
  fall back to kind for that one cluster, per `.claude/CLAUDE.md`'s
  Alternatives Considered table).
* Bad — and this is the one caveat the whole estate must keep honest:
  **multi-node k3d simulates scheduling topology, not failure isolation.**
  Every node in both clusters is a container on this one host, sharing this
  host's kernel and Docker daemon. Killing a k3d agent container kills a
  containerd process on an otherwise-healthy host; it has no equivalent to
  a real EC2 instance (and everything running on it) going down. Any
  interview answer, ADR, or study note derived from a drill against these
  clusters must say "this proves scheduling behaviour, not failure
  isolation" — never implying node-loss resilience was actually tested.
  See `docs/cluster-topology.md`'s "How this diverges from EKS" section for
  the full statement.

## Pros and Cons of the Options

### kind for both clusters

* Good, because it is closer to vanilla upstream Kubernetes than k3s (which
  strips some controllers and swaps etcd for SQLite by default) — the
  better choice if a phase's actual learning goal is etcd or control-plane
  internals specifically.
* Bad, because it idles heavier than k3d — running two clusters
  simultaneously and continuously all day during study sessions makes that
  steady-state cost the material factor on this project, not a benchmark
  footnote.
* Bad, because kind has no first-class local registry or LoadBalancer —
  both require manual containerd-patch scripting that k3d provides as
  flags.

### k3d for both clusters (chosen)

* See Decision Outcome and Consequences above.

### A single cluster with namespace separation

* Good, because it uses half the resources of two clusters and avoids any
  cross-cluster registry/DNS wiring entirely.
* Bad, because it collapses the platform/app split this project's own
  architecture depends on: `docs/cluster-topology.md`'s "what runs where"
  distinction (tooling vs. product workloads) becomes a convention instead
  of a structural boundary, and Phase 4/7's node-drain and topology-spread
  drills would be run against tooling and product workloads sharing the
  same node pool — a materially different (and less realistic) failure
  domain than the real platform/app cluster split this project models.
* Bad, because "two clusters, one for tooling and one for the product" is
  itself a common, interview-relevant real-world pattern this option would
  give up demonstrating.
