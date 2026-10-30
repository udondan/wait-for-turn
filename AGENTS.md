# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A composite GitHub Action. `action.yml` maps inputs to `INPUT_*` env vars (plus PR context like `PR_NUMBER`, `BASE_REF`, `HEAD_SHA`, `HEAD_REPO`, `UPDATE_TOKEN`) and runs `wait.sh`. All logic is in `wait.sh` (bash + `gh api` + `jq`). There is no build step and no package manager. README.md documents user-facing behavior; keep it, `action.yml` input descriptions and the header comment of `wait.sh` in sync when behavior changes.

## Commands

Tool versions are pinned in `mise.toml` (bats, shellcheck, actionlint, zizmor). These are what CI (`.github/workflows/test.yml`) runs:

- Tests: `bats test/`
- Single test: `bats test/wait.bats -f "takes the turn when it is free"` (`-f` is a regex on the test name)
- Lint: `shellcheck -x wait.sh test/bin/gh test/lib/*.bash test/helpers.bash test/wait.bats`
- Workflow lint: `actionlint` (also shellchecks every `run:` block) and `zizmor .`

## How wait.sh works

- **Lock**: the turn is held by the run that created the newest ref `refs/wait-for-turn/<workflow>/<n>`. Taking the turn = creating a commit (message `wait-for-turn: run <id>[, pull request <n>]`) and ref `<n+1>`. Ref creation returns HTTP 422 if it exists, which is the mutual exclusion. After creating, it re-checks the newest ref (a stale run may recreate an old number) and deletes older refs. The holder's run id / PR are parsed back from the lock commit message (`read_holder`), so that format is a contract.
- **Holder liveness** (`is_active`): active runs come from the *unfiltered* runs list filtered client-side, because the API's `status` filter is backed by a stale search index. A holder missing from that list is fetched directly; only a 404 or `completed` releases the turn, other errors keep it held.
- **Merge wait** (`merge_pending`): a successful holder whose PR has auto-merge keeps the turn until merged/closed, behind/dirty, new head commit, or `merge-wait-minutes`.
- **Queue**: active runs minus the holder, minus older runs of a PR that has a newer run (this run always stays), sorted by label weight desc, then `run_started_at`, then id.
- **Yield** (`find_pending`/`yielding`): before taking a free turn, the first run defers to open auto-merge PRs with higher weight whose branch is behind or whose head sha has no run yet, up to `yield-to-pending-minutes`.
- **Polling**: first in line (or turn free) sleeps `poll-interval-seconds`, others `queued-poll-interval-seconds`; PR labels are refreshed on the slow interval or when the turn is free.
- **Up to date** (`check_up_to_date`/`update_branch`): with `require-up-to-date`, fails when behind; with `update-token` it first runs `gh pr update-branch --rebase` (never for forks) and still exits 1, since the new commit starts a new run.
- **Commit status** (`set_status`): optional, only sent when changed, truncated to 140 chars; failure to set it disables it with a warning. An EXIT trap sets failure (or error on INT/TERM) unless the run took the turn.

## Test harness

Tests run the real `wait.sh` against a file-backed fake GitHub API:

- `test/bin/gh` is put first on `PATH` and answers `gh api` / `gh pr update-branch` from state files in `$FAKE_STATE`. Any call it doesn't know is logged as `UNHANDLED` and fails the test in `teardown`, so **a new API call in wait.sh needs a matching case in `test/bin/gh`**.
- `test/lib/fake-sleep.bash` is injected via `BASH_ENV` and replaces `sleep`: it advances `SECONDS` instead of waiting, runs per-tick scripts, and aborts after `FAKE_MAX_TICKS` (default 100) sleeps.
- `test/lib/state.bash` documents the state layout and has the builders (`add_run`, `add_pr`, `set_pr`, `complete_run`, `hold_lock`, `set_behind`, `fail_api`, `at_tick`, `stop_at_tick`, `on_api`). Use `at_tick <n> '<code>'` to change the world during wait.sh's nth sleep.
- `test/helpers.bash` sets the default env (this run is id 100 of PR 1, workflow `test.yml`) and assertions (`assert_locks`, `assert_holds`, `assert_last_commit_status`, `count_calls`, ...). Run the script with `run_wait`.

## Releases

release-please (`release-type: simple`) builds CHANGELOG.md and tags from conventional commits on main; the workflow then moves the major tag (`v1`) that users reference. PRs are squash-merged and the PR title must be a conventional commit (checked by `pr-conventional-title.yml`), since it becomes the commit release-please reads.
