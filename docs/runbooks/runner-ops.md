# Runbook: Self-Hosted Runner Operations (D-16, D-17, D-12)

**When to use this:** operating, troubleshooting, or extending the
`athena-runner@N` systemd pool, or deciding whether a green `act` run is
sufficient evidence for a given claim. Phases 2, 3, and 7 all target this
runner's exact label set in their `runs-on:` — read the Lifecycle and
Credentials sections before adding a new self-hosted job anywhere in this
estate.

**Facts later phases depend on** (Plan 06's `<output>` instruction, extended
by Plan 02-02 Task 3):

| Fact | Value |
|------|-------|
| Pinned runner version | `2.336.0` |
| Checksum source | `GET /orgs/{org}/actions/runners/downloads` (live, `manage_runners`-scoped token) — the actions/runner GitHub Releases page publishes no separate `.sha256` asset for this tarball; the org-downloads endpoint is the authoritative per-release source, independently re-verified with `sha256sum` against the downloaded artifact before the role was written |
| Exact label set | `self-hosted`, `linux`, `x64`, `athena-local` — `runs-on:` in every self-hosted job must match this list exactly |
| Runner group | `athena-selfhosted` (id 3), `visibility=selected` restricted to `athena-infra` only, `allows_public_repositories=true` — created live via the runners-groups API, since the org's Default group (id 1) ships `allows_public_repositories=false` and would silently refuse jobs from every repo in this estate (all four are public) |
| Registry push target that worked from CI | `localhost:5000` (host-side — the runner is a host process against the host Docker daemon, D-17) — proven live in `heavy-selfhosted.yml`, matches Plan 02's `registry-smoke.sh` finding exactly |
| act's local platform image | `athena/act-ubuntu-latest:act-latest` — `catthehacker/ubuntu:act-latest` (the medium tier) plus `ruby`, built locally, never pushed to a registry |
| **Pool size** | `athena_runner_pool_size: 2` (`ansible/roles/github-runner/defaults/main.yml`) — two ephemeral JIT instances, `athena-runner@1` and `athena-runner@2`, both registered under the `athena-runner-` name prefix. See "Why a pool" below. |
| Pinned CI toolchain | `terraform` (`athena_terraform_version`), `checkov` (`athena_checkov_version`), `awslocal` (`athena_awscli_local_version`) — D-14 golden-agent-image pins, installed by the role's toolchain block, shared across every pool instance since they're stateless CLI tools symlinked onto `/usr/local/bin` |

## Why a pool (D-12)

D-11 puts every job that needs `localhost:4566` — plan, apply, the
`awslocal` verify, `terraform test` — on this self-hosted runner. With a
single runner unit, a long `terraform apply` on `main` blocks every PR's
`plan` job behind it purely on **runner capacity**, which is
indistinguishable in the Actions UI from the **state-lock queuing**
IAC-03's drill is meant to demonstrate — you could watch a PR queue and not
be able to tell which phenomenon you were looking at. Two pool instances
separate the two: with capacity for two jobs at once, a queued PR plan next
to an in-flight `main` apply now queues (if it queues at all) on the S3
state lock, not on the runner. The `athena_runner_pool_size` knob exists so
it can be raised if a later phase needs more headroom.

## Lifecycle

One job, end to end, on **one pool instance** (`athena-runner@N`) is exactly
this sequence — every instance runs this same sequence independently, in
parallel with its siblings:

1. `systemctl start athena-runner@N` (or a restart from the loop below) runs
   `ExecStartPre` twice: first `rm -rf {{ home }}/_work-N` (belt-and-braces
   pristine-per-job guarantee beyond what `RuntimeDirectory` alone covers,
   scoped to this instance's own work folder so two concurrent jobs on
   different pool instances cannot contaminate each other's checkout), then
   `jitconfig.sh N`.
2. `jitconfig.sh N` reads the registration PAT from
   `/etc/athena-runner/github-runner-pat`, derives this instance's
   registered name (`athena-runner-N`), first **deregisters any stale
   same-name runner** (a live-discovered necessity — see Troubleshooting),
   then calls `POST /orgs/AuraBit/actions/runners/generate-jitconfig` and
   writes the single-use, ~1-hour-lived response to
   `/run/athena-runner-N/jitconfig.json` (mode 0600, this instance's own
   `RuntimeDirectory`-owned path so it is wiped by systemd on stop and never
   visible to a sibling instance).
3. `ExecStart` runs `run.sh --jitconfig "$(cat .../jitconfig.json)"`.
   `--jitconfig` implies `--ephemeral` — no separate `config.sh` step ever
   runs, and no reusable registration token is ever written anywhere.
4. The runner registers as `athena-runner-N`, shows `online` in the
   organisation's runner list, and listens for exactly one job.
5. The job runs. GitHub deregisters this runner the moment the job
   completes (or fails) — this is what "ephemeral" means operationally.
6. `run.sh` exits; systemd's `Restart=always` (5s `RestartSec`) starts this
   instance's unit again, and the cycle repeats from step 1 with a
   brand-new registration and a brand-new runner id — independent of
   whatever the other pool instance is doing at the time.

Both instances share the same underlying runner binary installation and OS
user home directory (`/home/athena-runner`) — only the `RuntimeDirectory`
(JIT config) and the `_work` checkout folder are instance-isolated, per D-12's
design. This means the runner binary's own `.runner`/`.credentials` files
under `/home/athena-runner` reflect whichever instance most recently
(re)registered, not a permanently-separate per-instance file; each running
process still holds its own in-memory session once started, so this does not
affect job execution — only a snapshot read of `.runner` between two
concurrent restarts can transiently show the other instance's data.
`verify-runner.sh` accounts for this: it asserts ephemerality via the same
shared path (matching Phase 1's documented evidence path) once per pool
instance, and asserts genuine pool-wide operation independently via the
organisation's runners API (distinct online names, both label-carrying).

**Observe each step:**

```bash
systemctl status athena-runner@1 athena-runner@2          # unit state, both instances
journalctl -u athena-runner@1 -u athena-runner@2 -f        # live lifecycle log, interleaved
set -a; . estate/athena-infra/.governance.env; set +a
curl -sS -H "Authorization: Bearer $GH_RUNNER_REG_PAT" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/orgs/$GITHUB_OWNER/actions/runners" | jq .
sudo cat /home/athena-runner/.runner | jq .               # most-recently-registered instance's state (id, Ephemeral, pool)
```

The runner `id` in the API response changes after every completed job on
either instance — that rotation **is** the observable proof of ephemeral
behaviour this estate relies on (see "What the API does not tell you"
below).

### What the API does not tell you

The org-level runners API (`GET /orgs/{org}/actions/runners`, both the list
and the single-runner detail form) is documented as returning an optional
`ephemeral` boolean, but this org has never once observed that field in a
response — live-verified while building this role, across dozens of calls.
`verify-runner.sh` does not assert against it for that reason; it reads
`sudo cat /home/athena-runner/.runner`'s own `"Ephemeral":"True"` field
instead, which is written by the runner's own JIT registration and is a
stronger source of truth than an API field that may simply be omitted.

## Credentials

- **The registration PAT** lives at `/etc/athena-runner/github-runner-pat`
  — a root-readable file **outside every estate repository**, owned
  `root:athena-runner`, mode `0440` (traversable only by root and the
  runner's own group; its parent directory `/etc/athena-runner` is
  `root:athena-runner`, mode `0750`, for the same reason — a 0440 file
  behind a `0750 root:root` directory is unreadable by anyone but root,
  which was a real bug caught live while building this role, see
  Troubleshooting).
- **Its single scope** is `manage_runners:org` on the `athena-ci-bot`
  account — nothing else. It is used **only** by `jitconfig.sh`, **only**
  to call `generate-jitconfig` and, since this plan's live finding, to look
  up and delete a stale same-name registration first. It is never the
  runner's own authentication credential, never written into the systemd
  unit, an Ansible variable, or any file inside an estate repository, and
  every Ansible task that touches its existence is `no_log`.
- **The fetched JIT config** is single-use, expires roughly an hour after
  issuance, and is written to `/run/athena-runner-N/jitconfig.json` (mode
  0600, one such path per pool instance) immediately before every start —
  never cached, never reused. `RuntimeDirectory=athena-runner-%i` means
  systemd deletes this instance-specific file on every stop, independent of
  whether the runner process cleaned up after itself, and never visible to
  a sibling instance.
- **The runner binary's own internal credential files** — `.credentials`,
  `.credentials_rsaparams` (an RSA private key used to sign the runner's
  session token requests), and `.runner` — are written by `run.sh` itself
  during `--jitconfig` startup, not by anything this role controls
  directly. A live finding this plan: with the OS's default umask these
  land world-readable (0644). `UMask=0077` in the systemd unit closes this
  for every file the service process creates, from the first write, with
  no post-hoc chmod race. All pool instances share the same runner-binary
  installation directory (`/home/athena-runner`), so these three files
  reflect whichever instance most recently (re)registered — see the
  Lifecycle section's note on what this does and does not affect.
- **Rotation:** the PAT is a normal fine-grained GitHub PAT — rotate it by
  minting a new one scoped identically, overwriting
  `/etc/athena-runner/github-runner-pat` (`sudo` required), and restarting
  every pool instance (`sudo systemctl restart athena-runner@1
  athena-runner@2`, or loop `athena_runner_pool_size` times). No code
  change is needed; the role never bakes the PAT's value into anything it
  renders.

## Blast radius

Stated honestly, not left implicit: the runner's OS user
(`athena-runner`) is a member of the `docker` group, which is
**root-equivalent on this host** — Docker's own security model treats
socket access as full root, since a container can be launched with
arbitrary host bind-mounts. This is the accepted cost of D-17's choice to
use the host Docker daemon (rather than Docker-in-Docker) so BuildKit's
layer cache persists in the host daemon across every ephemeral runner
instance — `heavy-selfhosted.yml`'s second build step proves this
concretely (a `CACHED` layer on a run that started from a brand-new
runner registration).

**Pooling multiplies this, and that is stated plainly too.** Every pool
instance runs as the same `athena-runner` OS user, so `athena_runner_pool_size`
instances is `athena_runner_pool_size` concurrent root-equivalent job slots,
not one. Raising the pool size raises the number of jobs that can be
running with that authority at the same moment — this is exactly why the
knob defaults to the smallest value (2) that actually solves D-12's
runner-vs-lock-queue ambiguity, rather than an arbitrarily larger number.
The four compensating controls below bound each individual job's blast
radius; they do not shrink as the pool grows, and neither does the
underlying accepted risk.

This risk is accepted, not ignored, and it is bounded by **four
independent compensating controls**:

1. **No PR-family trigger on any self-hosted job.** `heavy-selfhosted.yml`
   declares only `push` (limited to `main`) and `workflow_dispatch` —
   never a proposed-code-triggered event. `verify-runner.sh` asserts this
   mechanically on every run.
2. **A redundant job-level condition.** The `heavy` job also carries an
   `if` gating on `github.ref == 'refs/heads/main'`, deliberately
   duplicating what the trigger list already restricts — a control with a
   single point of failure is a control that fails silently the day
   someone adds a trigger without re-reading the comment above it.
   `verify-runner.sh` asserts this too.
3. **The org-level fork-approval policy** (Plan 05 user_setup — "Require
   approval for all outside collaborators" on each repo's Settings ->
   Actions -> General page). This has no API surface at all
   (`verify-governance.sh` reports it `MANUAL`) — its completion is a
   precondition of this runner's design being sound, and must be verified
   before treating this runner as safe to leave attached to a public repo.
4. **The org-wide action allowlist and required SHA-pinning**
   (`actions-security.tf`, Plan 05) — bounds what any workflow, including
   this one, can invoke to begin with.

None of these four alone is sufficient; together they are the actual
answer to "why is it safe to run a self-hosted runner against a public
repository on a personal workstation" — the honest interview answer is
"we accepted a real risk and here are the four controls that bound it,"
not "the risk doesn't exist."

## What act does not prove

`act` is for syntax and job-logic iteration — a fast inner loop before
anything is pushed. A green `act` run is **not** equivalent to a green run
on the real self-hosted runner or on GitHub-hosted infrastructure. This
list is the explicit statement of where parity does not hold; treat a
green `act` run as exactly the kind of false confidence this estate exists
to teach distrust of, and verify every item below against a real push:

1. **GitHub Environments' required-reviewer gating.** act has no concept of
   an Environment pausing a job for approval — `environment: stg`/`prod`
   jobs (Phase 2/3) run straight through under act with no pause at all.
2. **Concurrency-group queuing.** `concurrency:` blocks are parsed but not
   enforced the way GitHub's real scheduler enforces them across separate
   workflow runs — act only ever runs the one invocation you gave it.
3. **The merge queue.** `merge_group` events and `merge_queue` ruleset
   behaviour are GitHub-hosted-service concepts with no local equivalent;
   act cannot simulate queue ordering, `ALLGREEN` grouping, or the
   queue-specific checkout ref.
4. **Matrix behaviour against real runner labels.** act runs every job in
   one shared Docker network namespace regardless of the `runs-on:` labels
   declared — it does not distinguish `self-hosted` from `ubuntu-latest`
   the way GitHub's real scheduler routes jobs to different machines, and
   it never proves the job actually lands on *this* runner specifically.
5. **Org-level Actions policy.** The allowlist, SHA-pin requirement, and
   default read-only token permissions (`actions-security.tf`) are
   GitHub's own service-side enforcement — act's local Docker daemon has
   no knowledge of any of it and will happily run an action act itself
   fetched from wherever its own image resolution finds it.
6. **The exact runner image.** `athena/act-ubuntu-latest:act-latest`
   (medium tier + `ruby`) is not GitHub's real `ubuntu-latest` image —
   it is ~500MB against GitHub's real multi-gigabyte image, and it
   necessarily diverges in exactly the way this plan discovered (`ruby`
   missing) and will diverge again for any tool this estate's workflows
   come to depend on that isn't in the medium tier.

Every one of these must be verified against a real push. This plan's own
acceptance criteria never accept an `act` result as proof of a gating
behaviour — only of "the workflow file parses and this job's shell logic
runs."

## ARC, considered and rejected

Actions Runner Controller (ARC) would host a fleet of self-hosted runners
inside a Kubernetes cluster, scaling replicas per queued job rather than
running one systemd-managed process on a developer's own machine. It was
considered and rejected here for two reasons specific to this estate, not
because it is a bad tool in general:

- **The requirement fixes the runner on the local machine.** This project's
  entire premise is a strictly-$0, fully-local estate — ARC's value
  proposition (autoscaling a fleet against burst CI load) doesn't apply
  when there is exactly one machine and exactly one concurrent job ever
  possible.
- **It would strip Ansible of its one scoped role in this estate.** D-16
  explicitly frames `github-runner` as "the substance" of Ansible's
  presence here; running runners as Kubernetes pods instead would leave
  Ansible with nothing production-shaped left to do, undermining the
  reason Ansible is in this project's fixed tool list at all.

**Study-notes flag:** ARC is the right answer at fleet scale — many
autoscaling ephemeral runners behind a queue, provisioned declaratively via
a Kubernetes CRD (`RunnerScaleSet`), no systemd unit per machine to reason
about. It is the plausible v2 exploration for this project if the estate
ever needed to demonstrate CI at team scale rather than solo-developer
scale.

## Troubleshooting

**The runner never comes online.**
`journalctl -u athena-runner -n 50` first. Common causes, in the order
this plan hit them live:
- `jitconfig: cannot read PAT file ...` — the PAT file or its parent
  directory (`/etc/athena-runner`) isn't traversable by the `athena-runner`
  group. Both must be group-readable/traversable, not just the file
  itself; `ansible-playbook ansible/runner.yml` re-applies both fixes
  idempotently.
- `jitconfig: ... GitHub API said: Already exists - A runner with the name
  ... already exists.` — GitHub only auto-deregisters an ephemeral runner
  after it completes a job. An **administrative** restart (e.g. this role
  re-rendering the unit and notifying its handler) kills a not-yet-jobbed
  runner process without giving it the chance to deregister itself,
  leaving a stale `online` registration under this name.
  `jitconfig.sh` handles this automatically as of this plan (it looks up
  and deletes any stale same-name registration before requesting a new
  JIT config) — if you see this error anyway, `jitconfig.sh` on disk
  predates that fix; re-run `ansible-playbook ansible/runner.yml`.

**The configuration fetch fails for another reason.**
`jitconfig.sh` always prints GitHub's own `message` field on failure and
exits non-zero, which stops the unit from starting rather than silently
running an unregistered runner. Check the PAT hasn't expired or been
revoked, and that `GH_RUNNER_REG_PAT` still has `manage_runners:org` scope.

**A job hangs.**
`gh api /orgs/AuraBit/actions/runners --jq '.runners[] | select(.busy==true)'`
confirms whether the runner genuinely picked up a job. Check the Actions
run's own log first (`gh run view <id> --log`) — a hang inside a workflow
step is a workflow problem, not a runner problem, and killing the runner
process will not fix it (the job will simply show as failed once the
runner process is killed and systemd restarts it into a fresh
registration).

**The runner takes a job it should not have.**
This means one of the four Blast radius controls has a gap — treat it as
a security incident, not a bug. First:
```bash
sudo systemctl stop athena-runner@1 athena-runner@2   # stop every instance taking new jobs immediately
```
Then check which control failed: did a workflow add a PR-family trigger
(`verify-runner.sh` would have caught this on its next run — run it now),
did the org's fork-approval setting get reset, or did an allowlisted
action itself do something it shouldn't have? Do not restart either unit
until the root cause is identified and closed.

**Fully deregister and re-provision one pool instance** (substitute the
instance number, e.g. `1`, throughout):
```bash
set -a; . estate/athena-infra/.governance.env; set +a
sudo systemctl stop athena-runner@1
sudo systemctl disable athena-runner@1
RUNNER_ID="$(curl -sS -H "Authorization: Bearer $GH_RUNNER_REG_PAT" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/orgs/$GITHUB_OWNER/actions/runners" \
  | jq -r '.runners[] | select(.name=="athena-runner-1") | .id')"
curl -sS -X DELETE -H "Authorization: Bearer $GH_RUNNER_REG_PAT" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/orgs/$GITHUB_OWNER/actions/runners/${RUNNER_ID}"
sudo rm -rf /home/athena-runner/.athena-runner-version   # forces a fresh binary re-install too, if desired
ansible-playbook estate/athena-infra/ansible/runner.yml
```
