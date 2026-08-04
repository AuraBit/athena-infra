# Runbook: ArgoCD Sync Failures

**Scope:** the hub ArgoCD on `k3d-platform` (namespace `argocd`) managing 12
Applications (3 roots + 9 unit children) across the app cluster's
`dev`/`stg`/`prod` namespaces.
**Companions:** `scripts/verify-argocd.sh` (standing assertions),
`docs/runbooks/image-promotion-and-rollback.md` (when the "failure" is
actually a bad promotion).

## First triage — 60 seconds

```bash
kubectl --context k3d-platform -n argocd get applications
# Healthy estate: every row Synced / Healthy.
kubectl --context k3d-platform -n argocd get app <name> \
  -o jsonpath='{.status.conditions}{"\n"}{.status.operationState.message}{"\n"}'
```

Read the condition message before touching anything — nearly every failure
class below names itself there.

## Failure classes, most likely first

### 1. ComparisonError / repo unreachable
Symptom: `Unknown` sync status, condition mentions the repo URL.
- The hub reaches GitHub over HTTPS. Check platform-cluster egress:
  `kubectl --context k3d-platform -n argocd exec deploy/argocd-repo-server -- wget -qO- https://github.com >/dev/null`.
- If DNS fails in-cluster, re-apply the CoreDNS custom override
  (`clusters/*/coredns-custom.yaml`, `scripts/apply-coredns-custom.sh`) —
  the estate's known-fixed gap; the fix is idempotent.

### 2. x509 / cluster Secret failures (app-cluster children only)
Symptom: `the server has asked for the client to provide credentials` or a
certificate SAN mismatch naming an IP.
- The registered server URL MUST be the k3s server node's address
  (`docker inspect k3d-app-server-0 ...IPAddress`), never the serverlb —
  its IP is absent from the apiserver cert SANs (proven live, Plan 03-01).
- Container recreation changes these IPs. Re-derive and re-run
  `argocd/bootstrap/bootstrap-argocd.sh` (idempotent), which re-mints the
  ServiceAccount token and rewrites the cluster Secret.

### 3. OutOfSync that never converges
- `kubectl -n argocd get app <name> -o jsonpath='{.spec.source.path}'` —
  confirm the path points at `envs/<env>/<unit>` (rendered output), never
  `charts/` or `overlays/`.
- Run the render-check locally: `bash scripts/render-env.sh <env>` in
  athena-gitops, then `git diff envs/` — a dirty diff means someone
  committed chart/overlay changes without re-rendering (the render.yml
  gate should have caught it, check whether it was bypassed).
- Immutable-tag miss: if the pinned tag is absent from the registry
  (`curl -s http://localhost:5000/v2/athena-media/tags/list`) the pod
  sticks in ImagePullBackOff while the app shows Progressing — fix by
  reverting the pin commit, never by retagging.

### 4. Sync succeeds, workload unhealthy
- `kubectl --context k3d-app -n <env> get pods` and read the crash loop,
  not the Application object. Known estate example: upstream Boutique
  services need `DISABLE_PROFILER` set (crash-looped live in Plan 03-06).

### 5. Self-heal fighting a human
Symptom: a resource flaps every few seconds.
- Someone is kubectl-editing live state ArgoCD owns. That is CD-02 working.
  The fix is a commit, not a bigger kubectl. See the drift-revert drill.

## Break-glass

Pausing reconciliation for one Application (requires a recorded reason):
```bash
kubectl --context k3d-platform -n argocd patch app <name> --type merge \
  -p '{"spec":{"syncPolicy":null}}'      # restore from git afterwards — the
                                          # Application manifests are themselves synced
```
Restore by reverting to the committed manifest (`argocd/apps/<env>/`), never
by hand-editing the live object back.
