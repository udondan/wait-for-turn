# wait-for-turn

GitHub Action that waits until all earlier active runs of the same workflow have finished. Use it to keep runs from different branches from using shared resources (test stacks, environments) at the same time, without cancelling pending runs the way a `concurrency` group does.

Unlike actions that query runs with the `status` filter of the GitHub API, this action reads the unfiltered run list. The filtered list is backed by a search index that can be stale and miss active runs (see [softprops/turnstyle#165](https://github.com/softprops/turnstyle/issues/165)).

Runs are queued by start time. A re-run queues behind runs that started before it.

## Usage

```yaml
jobs:
  wait-for-turn:
    runs-on: ubuntu-latest
    timeout-minutes: 180
    permissions:
      actions: read
    steps:
      - uses: udondan/wait-for-turn@v1

  deploy:
    needs: wait-for-turn
    # ...
```

## Inputs

| Name                    | Default                     | Description                                                   |
| ----------------------- | --------------------------- | ------------------------------------------------------------- |
| `workflow`              | workflow of the current run | Workflow file name to queue on, e.g. `test.yml`.              |
| `poll-interval-seconds` | `30`                        | Seconds between checks.                                       |
| `timeout-minutes`       | `0`                         | Fail after waiting this many minutes. `0` waits indefinitely. |
| `token`                 | `github.token`              | Token with `actions: read` permission.                        |
