# protections.tf — branch rulesets that make `main` actually governed
# (REPO-02, D-01, D-02, D-03).
#
# D-01: trunk-based development, folder-per-env everywhere. Only `main` is
# protected in every repo — there are no `dev`/`stg`/`prod` branches anywhere
# in this estate, because environments are folders (athena-gitops's
# envs/dev|stg|prod) or Terraform working directories (Phase 2+'s per-env
# stacks), never branches. `~DEFAULT_BRANCH` is used instead of a literal
# "main" so this stays correct even if the default branch name ever changes.
#
# Ordering note: a required status check whose context names a job that has
# never reported once cannot always be selected as a required check, and a
# ruleset that requires a check which never exists makes `main` permanently
# unmergeable. Task 1 seeds and proves the `lint` job green on all four
# repos before this file exists — do not reorder that.

locals {
  # athena-ci-bot (Plan 04's SUMMARY, verified live): a plain GitHub *user*
  # account, not a GitHub App/Integration. RESEARCH.md's Pitfall 5 warns this
  # exact distinction is where bypass_actors silently deadlocks — the wrong
  # actor_type doesn't error, it just leaves the rule blocking with a
  # "required review not satisfied" message that looks like a policy problem
  # rather than a configuration one. actor_type = "User" is correct here,
  # not the "Integration" value RESEARCH.md's generic Pattern 3 example used
  # (that example assumed a GitHub App, which this bot is not).
  athena_ci_bot_user_id = 312349166

  # bypass_mode = "always" (not "pull_request"): the bot needs to push
  # directly to a protected `main` without going through a PR at all, for
  # the automated commit paths later phases add — Phase 3's gitops
  # promotion-commit job (D-04) and any future Terraform-apply-result commit
  # path. "pull_request" mode would only let the bot bypass rule
  # enforcement *within* a PR (e.g. merging past a failed check), which is
  # not what those direct-push automations need.
  athena_ci_bot_bypass = {
    actor_id    = local.athena_ci_bot_user_id
    actor_type  = "User"
    bypass_mode = "always"
  }
}

# --- athena-app ------------------------------------------------------------
#
# The only repository with code-owner review required and the only one with
# a merge queue (D-02). required_check.context = "lint" matches the job id
# in athena-app/.github/workflows/lint.yml exactly — a mismatch here is the
# specific failure mode that makes main permanently unmergeable.
#
# VERIFIED LIVE FINDING (Task 3's protected-merge walkthrough, real PRs
# #1/#2, this plan): athena-ci-bot's own PR review does NOT satisfy
# require_code_owner_review on this repo — GitHub's reviewDecision stayed
# REVIEW_REQUIRED even after the bot approved, because the bot is not a
# member of any CODEOWNERS team (teams.tf only adds developer_username to
# team memberships; Plan 04's territory, not edited by this plan). What
# DOES unblock the merge is bypass_actors above: the bot merging directly
# is exempt from ruleset enforcement entirely (the same grant that lets it
# push straight to main), independent of whether its review satisfied the
# review gate. This was proven by isolation on athena-docs in the same
# walkthrough (require_code_owner_review=false there): the identical bot
# review DID flip reviewDecision to APPROVED and mergeStateStatus to CLEAN,
# and a normal, non-bypass merge by the human author succeeded — so the
# review-count mechanism itself works correctly; only the code-owner
# sub-requirement is unreachable by the bot's review specifically on this
# repo. D-03's flow ("bot approves PRs") is therefore real in practice as
# "human opens PR, bot reviews for the audit trail, bot merges via bypass"
# on athena-app — not "bot's review satisfies the code-owner gate and a
# human clicks merge." Making the bot's review itself satisfy
# require_code_owner_review would require adding athena-ci-bot to
# team-platform (or all six teams) in teams.tf — a real, recommended
# follow-up for whichever plan next touches that file, not done here per
# this plan's explicit file-ownership boundary (Plan 04 owns teams.tf).
resource "github_repository_ruleset" "app_main" {
  name        = "protect-main"
  repository  = github_repository.athena_app.name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  bypass_actors {
    actor_id    = local.athena_ci_bot_bypass.actor_id
    actor_type  = local.athena_ci_bot_bypass.actor_type
    bypass_mode = local.athena_ci_bot_bypass.bypass_mode
  }

  rules {
    non_fast_forward = true # history cannot be rewritten with a force push
    deletion         = true # the branch itself cannot be deleted

    required_status_checks {
      required_check {
        context = "lint"
      }
      # Plan 03-07 Task 3 (POL-03/D-23): media-ci.yml's aggregator job. Required
      # only after the check had reported on the repository (gate=success on
      # a93cc74, run 30934151939) — the estate's confirm-before-require
      # precedent, so the ruleset cannot deadlock main on a never-reported check.
      required_check {
        context = "gate"
      }
    }

    pull_request {
      required_approving_review_count = 1
      require_code_owner_review       = true # CODEOWNERS enforcement lives on athena-app only (D-04's one-control-per-concern rule)
    }

    # D-02: GitHub merge queue on athena-app's main only. Native as of
    # integrations/github provider v6.13.0 (confirmed in
    # docs/runbooks/github-bootstrap.md's provider-coverage-gaps section) —
    # no gh api escape hatch needed for this control. ALLGREEN requires
    # every entry in the merge group to individually pass its checks,
    # matching D-02's "all entries green" requirement.
    merge_queue {
      grouping_strategy = "ALLGREEN"
    }
  }
}

# --- athena-infra ------------------------------------------------------------
#
# Approving review required; no code-owner review (no per-service ownership
# to simulate on this repo — D-04), no merge queue (D-02 restricts the queue
# to athena-app; this repo serialises concurrent changes at the
# terraform-<env> Actions-concurrency-group layer Phase 2 adds instead).
#
# D-32 (Plan 02-06 Task 3): a second required_check, context = "gate" —
# .github/workflows/terraform-core-network.yml's aggregator job id, read
# from that file rather than typed from memory (the file's own job-level
# comment records the same warning this file's header already states for
# `lint`: a required check naming a job that has never reported once makes
# `main` permanently unmergeable). Confirmed live, BEFORE this required
# check was added, that `gate` had already reported on `main` at least once
# (`gh api /repos/AuraBit/athena-infra/commits/main/check-runs` listed it
# among seven check-run names from Plan 02-04/02-05's already-merged PRs) —
# Phase 1's seed-and-prove-green-then-require ordering discipline, applied
# a second time.
#
# Exactly ONE aggregated check is listed here, never the individual matrix
# legs (`plan (dev)`, `plan (stg)`, `plan (prod)`, ...). A matrix leg for an
# environment nobody touched in a given PR is a leg that never runs at all
# — dorny/paths-filter reports no change for it, so
# terraform-core-network.yml's `plan` job's `strategy.matrix.env` simply
# never contains that leg — and a required check naming a leg that doesn't
# run for most PRs leaves that PR pending forever. `gate` is the one job
# that ALWAYS runs (`if: always()`, unconditional on every trigger) and
# that internally distinguishes an intentional skip (empty changed_envs, a
# modules-only PR; or a fork PR blocked by ADR-0006) from a leg that should
# have run and did not — see that job's own inline comments for exactly how
# it tells the two apart, including the empirically-discovered empty-matrix
# GitHub Actions quirk (Plan 02-04's Task 3 finding) it accounts for. One
# aggregator that always reports is the only shape compatible with a
# change-detection matrix and a required status check at the same time.
resource "github_repository_ruleset" "infra_main" {
  name        = "protect-main"
  repository  = github_repository.athena_infra.name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  bypass_actors {
    actor_id    = local.athena_ci_bot_bypass.actor_id
    actor_type  = local.athena_ci_bot_bypass.actor_type
    bypass_mode = local.athena_ci_bot_bypass.bypass_mode
  }

  rules {
    non_fast_forward = true
    deletion         = true

    required_status_checks {
      required_check {
        context = "lint"
      }
      required_check {
        context = "gate"
      }
    }

    pull_request {
      required_approving_review_count = 1
      require_code_owner_review       = false
    }
  }
}

# --- athena-gitops -----------------------------------------------------------
#
# Approving review required; no code-owner review, no merge queue — the
# bot's promotion-commit path (D-04) must stay fast, and a queue would sit
# directly in front of it. bypass_actors on this ruleset is what lets that
# promotion-commit job push straight to main once Phase 3 wires it.
resource "github_repository_ruleset" "gitops_main" {
  name        = "protect-main"
  repository  = github_repository.athena_gitops.name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  bypass_actors {
    actor_id    = local.athena_ci_bot_bypass.actor_id
    actor_type  = local.athena_ci_bot_bypass.actor_type
    bypass_mode = local.athena_ci_bot_bypass.bypass_mode
  }

  # Plan 03-08 (D-28) — NOTE, verified live: an Integration-type bypass for
  # the GitHub Actions app (id 15368) is SILENTLY DROPPED by GitHub's
  # ruleset API (the PUT succeeds, the entry never appears in a GET, while
  # the provider records it in state — permanent invisible drift). The
  # render pipeline therefore pushes nothing from CI at all:
  # render.yml is a render-CHECK (asserts committed envs/** match a fresh
  # deterministic render), and the only automated pusher to this repo's
  # main remains athena-ci-bot via the User bypass above (media-ci.yml's
  # gitops-handoff job commits the dev pin plus its rendered consequence).
  rules {
    non_fast_forward = true
    deletion         = true

    required_status_checks {
      required_check {
        context = "lint"
      }
      # Plan 03-09 Task 3: the shared "gate" aggregator context — reported
      # by render.yml's and promote.yml's gate jobs alike (the estate's
      # one-required-check convention, cf. terraform-*.yml). Required only
      # after render.yml's gate had reported success on main (two runs) —
      # the confirm-before-require precedent.
      required_check {
        context = "gate"
      }
    }

    pull_request {
      required_approving_review_count = 1
      require_code_owner_review       = false
    }
  }
}

# --- athena-docs -------------------------------------------------------------
#
# Approving review required; no code-owner review, no merge queue — same
# reasoning as infra/gitops above, this repo carries no pipeline at all.
resource "github_repository_ruleset" "docs_main" {
  name        = "protect-main"
  repository  = github_repository.athena_docs.name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  bypass_actors {
    actor_id    = local.athena_ci_bot_bypass.actor_id
    actor_type  = local.athena_ci_bot_bypass.actor_type
    bypass_mode = local.athena_ci_bot_bypass.bypass_mode
  }

  rules {
    non_fast_forward = true
    deletion         = true

    required_status_checks {
      required_check {
        context = "lint"
      }
    }

    pull_request {
      required_approving_review_count = 1
      require_code_owner_review       = false
    }
  }
}
