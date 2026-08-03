# 0003. Local DNS and TLS

* Status: accepted
* Date: 2026-08-03
* Deciders: Yahia Tarek (YahiaEng)
* Tier: short-form

## Context

The estate presents as a real company's platform: clean
`https://*.athena.net` and `https://*.platform.athena.net` URLs with no
port numbers and no certificate warnings, resolving entirely on this one
host with no internet dependency. Both need a wildcard DNS answer per
domain and a browser-trusted TLS chain per cluster.

## Decision

Wildcard DNS is served by **dnsmasq**, provisioned by the `bootstrap-dns`
Ansible role: `*.athena.net` -> `127.0.0.1` (app cluster loopback),
`*.platform.athena.net` -> `127.0.0.2` (platform cluster loopback). `nip.io`
was rejected — it needs internet access to resolve and would destroy the
`athena.net` domain fiction FOUND-04 exists for. `/etc/hosts` is documented
as a fallback for a host where dnsmasq cannot run, but is not the default
because it requires one entry per subdomain rather than one wildcard rule.

In-cluster TLS is issued by **cert-manager** in each cluster from a CA
`ClusterIssuer` backed by **mkcert's root CA**, materialized as a Kubernetes
`Secret` read from the host's `mkcert -CAROOT` at install time. Certificates
are declared as `Certificate` manifests in git, not created imperatively
with `kubectl create secret tls` — an imperative secret would be permanent,
unreconciled ArgoCD drift the moment GitOps starts watching this cluster in
Phase 3, which is exactly the failure mode declarative-over-imperative
(D-13) exists to prevent. Raw `kubectl create secret tls` remains a
documented break-glass fallback, not the default path.

## Consequences

* The host already trusts every certificate issued this way, because
  mkcert's root CA was installed into the host's trust store during
  bootstrap — no per-certificate trust step, and the browser-padlock check
  (Plan 01's tracer) passes with no warning.
* Each cluster's `ClusterIssuer` is an independent object even though both
  share the same CA material — a fact worth stating explicitly, because it
  is easy to assume shared state where there is none.
* Certificates auto-renew via cert-manager's own reconciliation loop, with
  no manual renewal step to remember or forget.
* The domain fiction depends entirely on this host's dnsmasq configuration
  — moving to a different host requires re-running the Ansible role, not a
  DNS registrar change, which is the correct trade for a $0 local project
  but would not transfer directly to a real multi-host deployment.
