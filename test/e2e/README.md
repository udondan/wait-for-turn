# End-to-end tests

The bats tests run `wait.sh` against a fake `gh` and a fake `sleep`. These tests run the action for real, in a throwaway public repository (`udondan/wait-for-turn-e2e` by default, set `E2E_REPO` to use another one): real runs, lock refs, auto-merge, rebases with a token, concurrency cancellation and commit statuses.

They don't run on pull requests. A scenario takes 3 to 15 minutes, all of them about 1.5 hours. Run them locally (see [Running](#running)) or with the workflow [End-to-end tests](../../.github/workflows/e2e.yml) (see [In GitHub Actions](#in-github-actions)).

## The test repository

`setup.sh [ref]` creates or updates the repository from `template/`, with the action at `ref` (default `main`, any branch, tag or commit of this repository):

- `pipeline.yml` calls the reusable workflow, then a `deploy` job uses a "shared resource" for `DEPLOY_SECONDS`, and `required` sums up both. The deploy takes the resource by creating the ref `refs/e2e-resource/pipeline`. If it exists, two deploys overlap: the deploy records `refs/e2e-resource/overlap-<run id>` and fails. It also fails on purpose when the branch has a file `fail-deploy`.
- `extra.yml` is a second required check, failing when the branch has a file `fail-extra`, so a pull request can pass the pipeline and still not be merged.
- `nostatus.yml` uses the action directly, without `statuses: write`. It only runs while the variable `NOSTATUS` is `true`.
- A ruleset on main requires `required` and `extra-check` and up-to-date branches. Auto-merge is on, squash only.
- The settings of the action come from repository variables (`POLL`, `QUEUED_POLL`, `TIMEOUT`, `MERGE_WAIT`, `YIELD`, `UPDATE_PENDING`, `USE_UPDATE_TOKEN`, `LABEL_WEIGHTS`, ...), so scenarios change them without a commit to main, which would make every open pull request behind. `lib.sh` has the defaults.

`setup.sh` can't set the token for rebases. Create a fine-grained personal access token for the test repository only, with **Contents** and **Pull requests** read and write, and store it:

```sh
gh secret set UPDATE_TOKEN -R udondan/wait-for-turn-e2e
```

Scenarios 06, 07, 09 and 10 need it.

## Running

To test a version from scratch, for example before a release:

```sh
test/e2e/run.sh --ref main             # setup.sh main, then all scenarios but 00
```

This takes about two hours. It exits 0 only if every scenario passed; `results/run.txt` gets a line per scenario.

```sh
test/e2e/setup.sh                      # once, or with a ref to test another version
test/e2e/scenarios/00-self-test.sh     # checks the harness catches an overlap
test/e2e/run.sh                        # all scenarios but 00, one after another
test/e2e/run.sh 03 06                  # some of them
```

### In GitHub Actions

The workflow `e2e.yml` runs `run.sh --ref <ref> [scenarios]`, started by hand: Actions → End-to-end tests → Run workflow, or

```sh
gh workflow run e2e.yml -R udondan/wait-for-turn -f ref=main               # all scenarios
gh workflow run e2e.yml -R udondan/wait-for-turn -f ref=main -f scenarios="03 06"
```

The job summary shows the PASS/FAIL lines, the artifact `e2e-results` has the logs and reports. Only one run at a time, a second one waits.

It needs the secret `E2E_TOKEN` in this repository: a fine-grained personal access token for the test repository only, with read and write for **Actions**, **Administration**, **Contents**, **Issues**, **Pull requests**, **Variables** and **Workflows**, and read for **Commit statuses** and **Secrets**. Keep it apart from `UPDATE_TOKEN`, so the action under test only gets the permissions users are told to give it.

```sh
gh secret set E2E_TOKEN -R udondan/wait-for-turn
```

Each scenario first resets the repository: it closes pull requests, cancels runs, deletes branches and lock refs and restores the default variables. Don't run two at the same time.

| Scenario              | What happens                                                                                       |
| --------------------- | -------------------------------------------------------------------------------------------------- |
| 01-smoke              | One pull request takes the turn, status pending, then success.                                     |
| 02-burst              | Six pull requests opened at once race for the lock, one deploy at a time.                          |
| 03-priorities         | Pull requests with different labels queue behind a holder and go by weight, then start time.       |
| 04-relabel            | Labelling a waiting pull request `urgent` moves it to the front.                                   |
| 05-new-commit         | A push to a waiting pull request cancels its old run (status error), the new one queues again.     |
| 06-renovate-storm     | Six Renovate pull requests with auto-merge are rebased, tested and merged one by one by themselves. |
| 07-yield              | A release pull request lets a Renovate pull request whose commit isn't tested yet go first.        |
| 08-yield-timeout      | The same, but the Renovate commit is never tested: the release goes after `yield-to-pending-minutes`. |
| 09-update-pending     | With `update-pending-branches`, the release run rebases Renovate pull requests that failed as behind. |
| 10-push-main          | Push runs of main (weight -100) go after the pull requests with auto-merge.                        |
| 11-failures           | A failed holder frees the turn at once, an unmergeable one only after `merge-wait-minutes`.        |
| 12-cancel-timeout     | Cancelled waiting run, timed out run, holder cancelled mid-deploy.                                 |
| 13-reruns             | A re-run of the holder keeps the turn, a later re-run queues again.                                |
| 14-no-status          | Without `statuses: write` the action warns and queues without the status.                          |

## Results

Each scenario writes `results/<scenario>-<time>/` (ignored by git):

- `snapshots.jsonl`: every 10 seconds, the lock refs with their holder, the pull requests (labels, auto-merge, head) and the active runs, by `observe.sh`.
- `final.json`: all runs since the start with their jobs, the annotations of the wait jobs, the commit statuses of every head commit and the pull requests, by `collect.sh` at the end.
- `report.json` and `summary.txt`: what `analyze.sh` found, and the checks of the scenario. `results/<scenario>.log` has the whole output, `results/run.txt` one line per scenario run by `run.sh`.

`analyze.jq` checks every scenario for:

- **mutual-exclusion**: no two "Use resource" steps of a workflow overlap and no overlap ref exists.
- **lock-integrity**: each lock number was taken by one run, and the deploys ran in lock order.
- **release**: no run took the turn before the holder completed, or, for a successful holder with auto-merge, before it was merged or `merge-wait-minutes` passed.
- **order**: the run that took the turn had the highest weight, then the earliest start, of the runs waiting at that time.
- **commit-status**: every run's statuses start pending and end with the state matching its wait job: success, failure, or error when cancelled.
- **idle-gap**: no deploy started more than `MAX_GAP` seconds (180 by default) after the previous one ended while runs waited.
- **all-completed**: no run is left active.

Scenarios add their own checks, like the expected turn order or status texts. A scenario exits 1 if any check fails. A failure that points at `wait.sh` gets a bats test that reproduces it before the fix.

## Cleaning up

The repository can stay for the next release. To delete it:

```sh
gh auth refresh -s delete_repo
gh repo delete udondan/wait-for-turn-e2e
```
