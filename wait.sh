#!/usr/bin/env bash
# Waits until no earlier run of the same workflow is active.
#
# The status filter of the list-runs API (?status=in_progress) is backed by a
# search index that can be stale and return no runs although runs are active.
# The unfiltered list is correct, so active runs are filtered client-side.
#
# Runs are queued by start time. A re-run gets a new start time and therefore
# queues behind runs that started before it.
set -euo pipefail

workflow="${INPUT_WORKFLOW:-}"
if [ -z "$workflow" ]; then
  # GITHUB_WORKFLOW_REF: owner/repo/.github/workflows/file.yml@refs/...
  workflow_path="${GITHUB_WORKFLOW_REF%%@*}"
  workflow="${workflow_path##*/}"
fi
interval="${INPUT_POLL_INTERVAL:-30}"
timeout_minutes="${INPUT_TIMEOUT_MINUTES:-0}"

runs_url="repos/$GITHUB_REPOSITORY/actions/workflows/$workflow/runs?per_page=100"
started=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" --jq .run_started_at)
echo "Run $GITHUB_RUN_ID of $workflow started at $started."

query="[.workflow_runs[]
  | select(.id != $GITHUB_RUN_ID and .status != \"completed\")
  | select(.run_started_at < \"$started\" or (.run_started_at == \"$started\" and .id < $GITHUB_RUN_ID))
  | .html_url] | join(\" \")"

deadline=0
if [ "$timeout_minutes" -gt 0 ]; then
  deadline=$((SECONDS + timeout_minutes * 60))
fi

while true; do
  if earlier=$(gh api "$runs_url" --jq "$query"); then
    if [ -z "$earlier" ]; then
      echo "No earlier run is active."
      exit 0
    fi
    echo "Waiting for $earlier"
  else
    echo "Listing runs failed, retrying."
  fi
  if [ "$deadline" -gt 0 ] && [ "$SECONDS" -ge "$deadline" ]; then
    echo "::error::Timed out after $timeout_minutes minutes waiting for earlier runs."
    exit 1
  fi
  sleep "$interval"
done
