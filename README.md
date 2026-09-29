# wait-for-turn

GitHub Action that queues the runs of a workflow so only one run at a time uses shared resources (test stacks, environments), without cancelling pending runs the way a `concurrency` group does. Runs are ordered by the labels of their pull requests, so for example your own pull requests are tested before dependency updates, and release pull requests last.

## How it works

The run that has the turn holds the lock ref `refs/wait-for-turn/<workflow>/<n>`. The turn is released when that run completes, including all jobs after the wait. The next run takes the turn by creating ref `<n+1>`. Creating a ref fails if it already exists, so only one run can take the turn. Old lock refs are deleted.

Waiting runs are ordered by weight (highest first), then by start time. A re-run of the run holding the turn keeps it. A re-run of any other run queues by its new start time.

The run that is next in line checks every `poll-interval-seconds`, the other waiting runs every `queued-poll-interval-seconds`. This keeps the API requests low when many runs are waiting. Labels are read while waiting, so labelling a pull request moves its waiting run in the queue.

Active runs are read from the unfiltered run list. The `status` filter of the GitHub API is backed by a search index that can be stale and miss active runs (see [softprops/turnstyle#165](https://github.com/softprops/turnstyle/issues/165)).

## Usage

```yaml
jobs:
  wait-for-turn:
    runs-on: ubuntu-latest
    timeout-minutes: 180
    permissions:
      actions: read
      contents: write
      pull-requests: read
    steps:
      - uses: udondan/wait-for-turn@v2
        with:
          require-up-to-date: true
          label-weights: |
            autorelease: pending=-10
            renovate=-5

  deploy:
    needs: wait-for-turn
    # ...
```

All runs of the workflow must use this action, otherwise they don't take part in the queue.

## Inputs

| Name                           | Default                     | Description                                                                 |
| ------------------------------ | --------------------------- | --------------------------------------------------------------------------- |
| `workflow`                     | workflow of the current run | Workflow file name to queue on, e.g. `test.yml`.                            |
| `label-weights`                |                             | Priority by pull request label, one `label=weight` per line (see below).    |
| `poll-interval-seconds`        | `30`                        | Seconds between checks of the run that is next in line.                     |
| `queued-poll-interval-seconds` | `300`                       | Seconds between checks of the other waiting runs.                           |
| `timeout-minutes`              | `0`                         | Fail after waiting this many minutes. `0` waits indefinitely.               |
| `require-up-to-date`           | `false`                     | Fail if the PR branch is behind its base branch (see below).                |
| `token`                        | `github.token`              | Token with `actions: read`, `contents: write` and `pull-requests: read`.    |

## Priorities

A run's weight is the sum of the weights of its pull request's labels. Runs without a pull request or without matching labels have weight 0. Negative weights move runs to the back of the queue, positive weights to the front. With the example above, unlabelled pull requests are tested first, then Renovate updates (configure Renovate with `"labels": ["renovate"]`), and release-please pull requests (labelled `autorelease: pending`) last. A label like `urgent=10` lets you move a single pull request to the front.

The run holding the turn is never interrupted: a higher weight only affects which waiting run is next.

## Outdated branches

With branch protection requiring branches to be up to date, testing a branch that is behind its base branch is wasted time: it has to be updated and tested again. With `require-up-to-date: true`, the action fails as soon as the branch is behind, while waiting and right before taking the turn. An outdated run stops right away and makes room for the run of the updated branch.

## Limitations

Pull requests from forks and from Dependabot get a read-only token and can't create the lock ref. The action then fails with a permission error.
