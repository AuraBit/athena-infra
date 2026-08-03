# 0002. Envoy Gateway as the Gateway API Implementation

* Status: accepted
* Date: 2026-08-03
* Deciders: Yahia Tarek (YahiaEng)
* Tier: full-madr

## Context and Problem Statement

Both k3d clusters need L7 HTTP routing and TLS termination for the
`athena.net`/`platform.athena.net` domain fiction (FOUND-04), and Phase 4's
Argo Rollouts needs a traffic-shifting data plane with real Gateway API
conformance for canary and blue-green steps. k3s bundles Traefik as its
default ingress controller, but that bundled install is not the answer this
project wants — the choice of Gateway API implementation is itself an
interview-relevant decision, and 2026 has retired the most commonly-assumed
default (ingress-nginx).

## Decision Drivers

* ingress-nginx's best-effort maintenance ended March 2026 with no further
  releases, bugfixes, or CVE patches — building new local-routing config on
  a dead controller undermines this project's "current, production-grade"
  positioning.
* Phase 4's Argo Rollouts canary/blue-green steps need reference-grade
  Gateway API conformance for weighted traffic splitting between
  ReplicaSets — not every implementation's conformance is equal.
* Removing Istio (out of scope, see the no-service-mesh ADR) means the data
  plane choice is also this project's only remaining chance to demonstrate
  enterprise-standard L7 proxy behaviour and rate-limiting/policy CRDs.
* k3d cluster creation must disable k3s's bundled Traefik in the same
  invocation that taints the server node — tainting after the fact hangs
  forever waiting on an untolerated Traefik pod (a documented k3d pitfall).

## Considered Options

* **ingress-nginx.**
* **k3s's bundled Traefik**, left enabled at its default install.
* **Traefik installed explicitly via the Gateway API**, rather than the
  bundled ingress-mode install.
* **Envoy Gateway.** (Chosen.)

## Decision Outcome

Chosen option: **"Envoy Gateway,"** installed on both clusters via its own
Helm chart with `crds.enabled=true` owning Gateway API CRD installation in
the same atomic `helm install` as its native CRDs (a deviation from the
originally-researched standalone `kubectl apply` CRD step — see the
"Consequences" note below), because Envoy is the enterprise-standard data
plane (recovering some of the mesh-adjacent interview surface this project
gives up by not running Istio), ships reference-grade Gateway API
conformance for Phase 4's Rollouts traffic shifting, and exposes standard
rate-limiting and policy CRDs beyond what Traefik's Gateway API support
offers at the same maturity.

### Consequences

* Good, because Envoy Gateway's conformance directly serves Phase 4's
  canary/blue-green weighted-traffic-splitting requirement — the data plane
  choice was made with that later phase in mind, not just this phase's
  smoke test.
* Good, because k3s's bundled Traefik is disabled at cluster-create time in
  both `k3d/app-cluster.yaml` and `k3d/platform-cluster.yaml`
  (`--disable=traefik` in the same invocation as the server taint), so
  there is no competing ingress path to reason about.
* Bad — and this is a real, live-discovered deviation from the original
  plan — installing Gateway API CRDs via a standalone `kubectl apply`
  before the Envoy Gateway Helm install (the originally-researched
  sequence) hard-conflicts under Helm v4: the chart's own `crds` subchart
  installs Gateway API CRDs via Server-Side Apply, and SSA-installing over
  a CRD already owned by `kubectl apply`'s client-side-apply field manager
  fails with `Apply failed with N conflicts`. The fix, applied and verified
  live in Plan 01: let the Envoy Gateway chart's `crds.enabled=true`
  default own Gateway API CRD installation entirely, removing the
  standalone `kubectl apply` step. This also guarantees CRD/controller
  version match (the chart's own bundled CRD version, v1.5.1 at execution,
  is authoritative — not the v1.6.1 standalone release originally cited).
* Bad, because each cluster needs its own independent Envoy Gateway install
  and its own independent `ClusterIssuer` object, even though both share
  the same mkcert CA material — not shared state, two objects that must
  each be created (see ADR-0003).

## Pros and Cons of the Options

### ingress-nginx

* Good, because it is the most widely-known ingress controller and the
  default many tutorials still assume.
* Bad, because it is retired: best-effort maintenance ended March 2026, no
  further releases, bugfixes, or CVE patches — a disqualifying reason for a
  2026-dated project whose interview value depends on demonstrating current
  practice.

### k3s's bundled Traefik, left enabled

* Good, because it requires zero extra install — it ships with k3s by
  default.
* Bad, because the bundled install is ingress-mode, not configured for
  Gateway API from the start, and re-configuring it after the fact fights
  k3s's own defaults rather than starting clean.
* Bad, because it gives up the enterprise-data-plane interview surface
  Envoy provides, and its Gateway API conformance/rate-limiting maturity
  trails Envoy's at time of research.

### Traefik installed explicitly via the Gateway API

* Good, because it is the simpler of the two Gateway-API-native options —
  less configuration surface than Envoy Gateway.
* Bad, because it doesn't recover the enterprise-data-plane interview
  surface this project loses by not running a service mesh — Envoy is the
  more commonly-referenced "if not a mesh, then what" answer at target
  companies.
* Bad, because its rate-limiting/policy CRD story is comparatively thinner
  than Envoy Gateway's at the version pinned in this project.

### Envoy Gateway (chosen)

* See Decision Outcome and Consequences above.
