# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A composite GitHub Action. `action.yml` maps inputs to `INPUT_*` env vars (plus PR context like `PR_NUMBER`, `BASE_REF`, `HEAD_SHA`, `HEAD_REPO`, `UPDATE_TOKEN`) and runs `wait.sh`. All logic is in `wait.sh` (bash + `gh api` + `jq`). There is no build step and no package manager. `.github/workflows/wait-for-turn.yml` is a reusable workflow (`on: workflow_call`, never runs on its own) with the recommended wait job; it calls the action with `uses: $/`, the same commit, and `test.yml` calls it on every PR as a test. README.md documents user-facing behavior; keep it, `action.yml` input descriptions, the inputs of the reusable workflow and the header comment of `wait.sh` in sync when behavior changes.

## Commands

Tool versions are pinned in `mise.toml` (bats, ruby, shellcheck, actionlint, zizmor), gem versions in `Gemfile`. These are what CI (`.github/workflows/test.yml`) runs:

- Tests: `bats test/`
- Single test: `bats test/wait.bats -f "takes the turn when it is free"` (`-f` is a regex on the test name)
- Coverage: `bundle install`, then `bundle exec bashcov -- test/coverage.sh` (on macOS add `--bash-path "$(command -v bash)"`, bashcov defaults to `/bin/bash` 3.2). Writes `coverage/index.html` and `coverage/coverage.xml`, which CI uploads to Codecov. Only `wait.sh` is traced and counted, see `test/coverage.sh` and `.simplecov`. Coverage is 100%: avoid commands continued with a trailing `\` in `wait.sh`, bashcov counts their first line as never run. Put long jq programs and fixed arguments into variables instead (like `queue_query` and `queue_args`).
- Lint: `shellcheck -x wait.sh test/bin/gh test/lib/*.bash test/helpers.bash test/wait.bats test/coverage.sh test/e2e/*.sh test/e2e/scenarios/*.sh test/e2e/template/scripts/*.sh`
- Workflow lint: `actionlint` (also shellchecks every `run:` block), `actionlint test/e2e/template/.github/workflows/*.yml` and `zizmor .`. actionlint doesn't know `$/` yet, `.github/actionlint.yaml` ignores those two errors.

## How wait.sh works

- **Lock**: the turn is held by the run that created the newest ref `refs/wait-for-turn/<workflow>/<n>`. Taking the turn = creating a commit (message `wait-for-turn: run <id>[, pull request <n>]`) and ref `<n+1>`. Ref creation returns HTTP 422 if it exists, which is the mutual exclusion. After creating, it re-checks the newest ref (a stale run may recreate an old number) and deletes older refs. The holder's run id / PR are parsed back from the lock commit message (`read_holder`), so that format is a contract.
- **Holder liveness** (`is_active`): active runs come from the *unfiltered* runs list filtered client-side, because the API's `status` filter is backed by a stale search index. A holder missing from that list is fetched directly; only a 404 or `completed` releases the turn, other errors keep it held.
- **Merge wait** (`merge_pending`): a successful holder whose PR has auto-merge keeps the turn until merged/closed, behind/dirty, blocked by a failed required check (GraphQL `isRequired`, a read error keeps waiting), new head commit, or `merge-wait-minutes`.
- **Queue**: active runs minus the holder, minus older runs of a PR that has a newer run (this run stays, but `check_newer_run` fails it if the newer run is of another commit), sorted by label weight desc, then `run_started_at`, then id.
- **Yield** (`find_pending`/`yielding`): before taking a free turn, the first run defers to open auto-merge PRs with higher weight whose head sha has no run yet, up to `yield-to-pending-minutes`. A tested PR that is behind is not waited for, unless `update-pending-branches` (needs `update-token`, never forks): then `check_head` rebases it and defers to its new commit.
- **Polling**: first in line (or turn free) sleeps `poll-interval-seconds`, others `queued-poll-interval-seconds`; PR labels are refreshed on the slow interval or when the turn is free.
- **Up to date** (`check_up_to_date`/`update_branch`): with `require-up-to-date`, fails when behind; with `update-token` it first runs `gh pr update-branch --rebase` (never for forks) and still exits 1, since the new commit starts a new run.
- **Commit status** (`set_status`): optional, only sent when changed, truncated to 140 chars; failure to set it disables it with a warning. An EXIT trap sets failure (or error on INT/TERM) unless the run took the turn.

## Test harness

Tests run the real `wait.sh` against a file-backed fake GitHub API:

- `test/bin/gh` is put first on `PATH` and answers `gh api` / `gh pr update-branch` from state files in `$FAKE_STATE`. Any call it doesn't know is logged as `UNHANDLED` and fails the test in `teardown`, so **a new API call in wait.sh needs a matching case in `test/bin/gh`**.
- `test/lib/fake-sleep.bash` is injected via `BASH_ENV` and replaces `sleep` and `wait` (wait.sh sleeps with `pause`, `sleep n & wait $!`, so the INT/TERM trap runs right away): it advances `SECONDS` instead of waiting, runs per-tick scripts, and aborts after `FAKE_MAX_TICKS` (default 100) sleeps. With `FAKE_REAL_SLEEP` it really sleeps, for signal tests.
- `test/lib/state.bash` documents the state layout and has the builders (`add_run`, `add_pr`, `set_pr`, `complete_run`, `hold_lock`, `set_behind`, `fail_api`, `at_tick`, `stop_at_tick`, `on_api`). Use `at_tick <n> '<code>'` to change the world during wait.sh's nth sleep.
- `test/helpers.bash` sets the default env (this run is id 100 of PR 1, workflow `test.yml`) and assertions (`assert_locks`, `assert_holds`, `assert_last_commit_status`, `count_calls`, ...). Run the script with `run_wait`.

## Releases

release-please (`release-type: simple`) builds CHANGELOG.md and tags from conventional commits on main; the workflow then moves the major tag (`v1`) that users reference. PRs are squash-merged and the PR title must be a conventional commit (checked by `pr-conventional-title.yml`), since it becomes the commit release-please reads.

## End-to-end tests

`test/e2e/` runs the action for real in the throwaway repository `udondan/wait-for-turn-e2e`: scenarios open parallel pull requests, an observer records lock refs, runs and pull requests, and an analyzer checks mutual exclusion, order, release and commit statuses. Not run on pull requests, a scenario takes 3 to 15 minutes, all about 1.5 hours: run `test/e2e/run.sh --ref <ref>` locally or start the workflow `e2e.yml` (`gh workflow run e2e.yml -f ref=<ref>`, needs the secret `E2E_TOKEN`). See `test/e2e/README.md`. A behavior change that the bats tests can't show (API timing, auto-merge, rebases with a token, cancellation) should get a scenario there.
