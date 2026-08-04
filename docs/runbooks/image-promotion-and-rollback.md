# Runbook: Image Promotion and Rollback

**Scope:** the media image's path through environments — automatic into
dev (media-ci's `gitops-handoff`), gated into stg and prod
(`athena-gitops/.github/workflows/promote.yml`).
**Contract:** promotion copies a pin forward, rollback reverts a commit.
Nothing in either path rebuilds an image or touches a cluster.

## Normal promotion (dev -> stg -> prod)

1. Dispatch `promote` in athena-gitops (Actions tab): choose target
   environment (`stg` or `prod`) and unit. There is deliberately no tag
   input — stg promotes what dev runs, prod promotes what stg runs.
2. The `resolve` job posts the rendered diff into the run summary and
   commits nothing. Read the diff — that is the approval's entire meaning.
3. Approve the `commit` job's environment gate (human reviewer, never the
   bot). The bot then commits pin + re-rendered manifests to main.
4. ArgoCD syncs the target env. Confirm:
   ```bash
   kubectl --context k3d-platform -n argocd get app media-<env> \
     -o jsonpath='{.status.sync.status} {.status.health.status}'
   kubectl --context k3d-app -n <env> get deploy media \
     -o jsonpath='{.spec.template.spec.containers[0].image}'
   ```

### Expected refusals (working as designed)
- unknown environment, or promoting into an env with no source below it
- no-op (target already runs the source's tag)
- tag absent from the registry (`athena-media` tags list is consulted —
  promoting an unservable image is refused at resolve time)

## Rollback — one revert, no rebuild

```bash
cd estate/athena-gitops
git log --oneline -5 -- overlays/<env>/ envs/<env>/   # find the promotion commit
git revert <promotion-sha>
git push origin main            # as an actor allowed on main (bot bypass or PR)
```
The revert restores the pin AND its rendered manifests together — ArgoCD
syncs it exactly as it synced the promotion. Verify with the same two
kubectl commands above. Never roll back by retagging in the registry
(immutability is enforced — the publish job refuses overwrites) and never
by kubectl-editing the Deployment (self-heal reverts you, correctly).

## Dev's automatic path, when it stalls

Merge landed on athena-app but dev's pin didn't move:
1. `gh run list --workflow=media-ci.yml` — find the merge-commit run; the
   publish/handoff jobs only run on default-branch pushes with media
   changes and successful build+scan.
2. Runner queue: publish runs on the self-hosted runners — check
   `ps aux | grep Runner.Listener` on the host and runner-ops.md.
3. If publish succeeded but the handoff commit is missing, check the run's
   handoff logs for the push — the bot credential (`ATHENA_CI_BOT_TOKEN`)
   is presence-asserted by `governance/secrets.tf` (`terraform plan` warns
   if it vanished).
4. Re-running the failed handoff job is safe — it no-ops if the pin
   already carries the tag.
