# Runbook: GitHub Governance Bootstrap (the chicken-and-egg step)

**When to use this:** setting up the estate's GitHub presence from scratch —
a fresh org, a fresh machine account, or recovering after losing the
governance stack's local Terraform state (D-10). This is the one part of the
governance story that is **not reproducible from `terraform apply` alone**:
three objects must exist before Terraform can manage anything, because
Terraform cannot create the identity it authenticates against, nor the repo
that will hold its own code.

## What must be created by hand

Three objects, in this order, and each one cannot be Terraformed for a
specific structural reason — not because nobody wrote the resource yet:

1. **The GitHub organisation.** GitHub's REST/GraphQL API has no
   "create organisation" endpoint — org creation is a UI-only,
   account-holder-driven flow (`github.com/organizations/plan`). No Terraform
   provider can call an API that doesn't exist.
   - Location: `github.com/organizations/plan` -> Free plan.
   - Verify availability of the intended login first; see "Recovering from a
     fallback-suffix login" below if it's taken.

2. **The machine account** (`athena-ci-bot`, D-03). This is a **second,
   distinct GitHub user account** — it needs its own email address and must
   complete GitHub's own email verification flow before it can be invited
   anywhere. No API can complete an email-verification loop on a human's
   behalf; this is a genuine "a person must click a link in an inbox" step.
   - Location: `github.com/signup` (use an email address distinct from the
     developer's own), then, once verified, the org -> People -> Invite
     member, with the **Owner** role (not Member) — D-03's design requires
     the bot to hold org-owner-level authority so it can approve PRs the
     solo developer cannot self-approve.

3. **The `athena-infra` repository, empty.** Public, no auto-init (no
   README/LICENSE/gitignore created by GitHub). This is the one repository
   Terraform must **import** rather than create, because it's the repository
   that will hold the very Terraform code managing the org — the code cannot
   exist in a place that doesn't exist yet.
   - Location: `github.com/organizations/<org-login>/repositories/new`.

Every other repository (`athena-app`, `athena-gitops`, `athena-docs`) and
every team, team membership, and repository grant is created **by**
`terraform apply` once the three objects above exist and are imported — no
further manual GitHub UI steps are needed for D-09's governance stack.

## Credentials needed

Three tokens, all minted from the `athena-ci-bot` account (not the
developer's own account — Terraform authenticates as the bot, matching D-03's
design that a distinct identity, not the developer, performs org actions):

| Variable | Scope | Used by | Never stored in |
|---|---|---|---|
| `GITHUB_TOKEN` | Org admin + repo + workflow (fine-grained or classic PAT) | `governance/*.tf` (this stack) | Any tracked file. Lives in `estate/athena-infra/.governance.env` (git-ignored) and/or `governance/terraform.tfvars` (also git-ignored) locally; a CI-scoped secret once Phase 2+ needs it. |
| `GITHUB_OWNER` | n/a (not a secret, but kept alongside the token for convenience) | Same as above | Same file. |
| `GH_RUNNER_REG_PAT` | `manage_runners:org` only | Plan 06's self-hosted runner JIT-config fetch | Same file — created now, while already in the bot account's PAT UI, per D-16's ephemeral-runner design; used only to *fetch* a short-lived JIT config, never as the runner's own long-lived auth (RESEARCH.md's JIT-config anti-pattern warning). |

Load them into a shell with:

```bash
set -a; . estate/athena-infra/.governance.env; set +a
```

Never `echo`, log, or commit the values of any of these three variables. The
example file (`governance/terraform.tfvars.example`) names the variables
with **no** value — that's the only tfvars file this repo tracks.

## Import sequence

Once the three manual objects exist and the credentials above are exported:

```bash
cd estate/athena-infra/governance
terraform init
export TF_VAR_github_token="$GITHUB_TOKEN"   # keeps the PAT out of terraform.tfvars entirely
./imports.sh
terraform plan -detailed-exitcode
```

`imports.sh` runs two imports (idempotent — safe to re-run; it skips any
resource already present in state):

```bash
terraform import github_organization_settings.this <numeric-org-id>   # fetched live by the script, not hardcoded
terraform import github_repository.athena_infra athena-infra
```

**The success condition is that the `terraform plan` immediately afterward
reports NO CHANGES for both imported resources** (`-detailed-exitcode`
returns `0`, not `2`). This is the whole point of the import step: an import
that leaves a diff means the Terraform code does not accurately describe
what was actually hand-bootstrapped — a real config mismatch that will either
silently drift or get clobbered on the next `apply`, not a cosmetic
difference to ignore. If the plan shows an unexpected diff after import,
fix the `.tf` code to match the live resource before running `apply` — never
the reverse (never hand-edit the live org/repo to match a wrong plan).

Once both imports produce a clean plan, `terraform apply` creates everything
else this stack declares — the remaining three repositories, six teams, all
team memberships, and every `github_team_repository` grant — with **no**
further manual GitHub UI steps.

## Recovering from a fallback-suffix login

If the intended org login (originally `athena-platform` per CONTEXT.md D-06)
is unavailable — as it was live at this plan's execution, already owned by
an unrelated account — the org gets created under a different login instead
(this estate uses `AuraBit`, created fresh and confirmed owned by the
developer). Recovery is a single-variable change, not a re-bootstrap:

1. Update `governance/variables.tf`'s `github_owner` default (or override via
   `terraform.tfvars`/`TF_VAR_github_owner`) to the actual login used.
2. Update `estate/athena-infra/.governance.env`'s `GITHUB_OWNER` to match.
3. Re-run the import sequence above against the new login — the numeric org
   ID `imports.sh` fetches is looked up live from `GITHUB_OWNER`, so no
   hardcoded ID needs updating.
4. Grep the estate for the old login string before trusting anything else —
   a stale reference in a README, a Go module path, or a doc is a silent
   correctness bug, not a cosmetic one, since the org name is baked into
   image references, ArgoCD repo URLs, and CODEOWNERS entries per D-05's
   one-way reversibility rating.

## Provider coverage gaps

D-10 anticipated that some GitHub configuration would fall outside the
`integrations/github` Terraform provider's coverage and need a documented
`gh api` escape-hatch script. This section is where every such gap gets
named explicitly — a scripted workaround belongs in this repo next to the
Terraform it compensates for, never left implicit in someone's shell
history.

**Verified finding: the anticipated merge-queue gap is already closed.** As
of `integrations/github` provider v6.13.0 (the version pinned in
`governance/main.tf`), `github_repository_ruleset` has a native
`rules.merge_queue` block (`grouping_strategy`, `merge_method`,
`max_entries_to_merge`, etc.) — confirmed directly against the pinned
version's own provider documentation. D-02's requirement (GitHub merge queue
on `athena-app`'s `main`, and nowhere else) is fully Terraform-managed by
Plan 05's `protections.tf`; **no `gh api` script is needed for this gap.**

**Plan 05 finding: fork-PR-approval-for-outside-collaborators has NO API at
all — not a provider gap, a total API gap.** D-08/CI-06 requires "require
approval for fork pull requests from all outside collaborators." This
setting (GitHub Settings -> Actions -> General -> "Fork pull request
workflows from outside collaborators", configured per repository) was
probed directly and exhaustively this plan:

- Every plausible REST path was tried against both org- and repo-scoped
  `actions/permissions/*` endpoints — each returned a generic 404 with
  `documentation_url: https://docs.github.com/rest` (GitHub's signature for
  "this route does not exist," distinct from the specific,
  doc-linked 404/409 responses the real neighbouring endpoints return).
- GraphQL schema introspection on both the `Organization` and `Repository`
  types was queried for every field containing "fork" — none relate to
  workflow-approval policy.

Because no API exists — not "the `integrations/github` provider doesn't
expose it," but "there is nothing for any provider, or any `gh api` script,
to call" — this is **not closable by a companion script**, unlike the
general escape-hatch procedure below assumes is always possible. It is
recorded as a genuine, permanent manual step: for each of the four
repositories, Settings -> Actions -> General -> "Fork pull request
workflows from outside collaborators" -> "Require approval for all outside
collaborators" -> Save. `scripts/verify-governance.sh` reports this item as
`MANUAL`, not a fabricated `PASS` — see `governance/actions-security.tf`'s
own comment for the full evidence trail. Re-check this specific gap
whenever GitHub's REST/GraphQL API changelog is reviewed; if an endpoint is
ever added, adopt it into `actions-security.tf` the same way the
merge-queue gap above was retired once the provider caught up.

**Plan 05 finding: `GET /repos/{owner}/{repo}/codeowners/errors` 404s
unless `ref` is a fully-qualified `refs/heads/<branch>`.** Calling this
endpoint with `?ref=main` (or no `ref` at all) returns a generic 404 even
when a valid `CODEOWNERS` file exists on the default branch; calling it
with `?ref=refs/heads/main` returns the expected `{"errors": []}` body.
This is an endpoint-usage quirk, not a provider or Terraform gap (this
endpoint isn't Terraform-managed at all — it's a read-only validation
check), but it cost real debugging time this plan and is recorded here so
the next script that calls it doesn't rediscover it the hard way.
`scripts/verify-governance.sh` already uses the fully-qualified form.

**No other provider coverage gap has been identified as of this plan.**

**The general escape-hatch procedure, for whatever gap does surface next
(where an API DOES exist but the Terraform provider doesn't expose it —
distinct from the total-API-gap case documented above):**

1. Confirm it's a genuine coverage gap (the field/behaviour exists in the
   GitHub API/UI but has no corresponding Terraform provider resource or
   argument at the pinned version) — not a config mistake.
2. Name the gap explicitly in this section: what it is, why it isn't
   Terraform-managed, and a link to the relevant provider issue/PR if one
   exists upstream.
3. Write a small, idempotent script (`gh api ...`) that closes the gap,
   living in `governance/` next to the `.tf` files it complements — not a
   one-off command run manually and forgotten.
4. Re-check this section whenever the pinned provider version bumps — a gap
   documented here today may close natively in a later provider release
   (exactly what happened with the merge-queue gap above), at which point
   the script should be deleted and the resource adopted into Terraform
   properly, not left running alongside a now-redundant native option.
