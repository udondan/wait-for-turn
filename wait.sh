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
require_up_to_date="${INPUT_REQUIRE_UP_TO_DATE:-false}"

if [ "$require_up_to_date" = "true" ] && { [ -z "${BASE_REF:-}" ] || [ -z "${HEAD_SHA:-}" ]; }; then
  echo "::notice::require-up-to-date only applies to pull_request events, skipping the check."
  require_up_to_date=false
fi

# Fails the run if the branch is behind the base branch. Testing an outdated
# branch is wasted time: it has to be updated and tested again anyway.
check_up_to_date() {
  [ "$require_up_to_date" = "true" ] || return 0
  local behind
  if ! behind=$(gh api "repos/$GITHUB_REPOSITORY/compare/$BASE_REF...$HEAD_SHA" --jq .behind_by); then
    echo "Comparing with $BASE_REF failed, retrying later."
    return 0
  fi
  if [ "$behind" -gt 0 ]; then
    echo "::error::Branch is $behind commit(s) behind $BASE_REF. Update the branch to run the tests."
    exit 1
  fi
}

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
  check_up_to_date
  if earlier=$(gh api "$runs_url" --jq "$query"); then
    if [ -z "$earlier" ]; then
      echo "No earlier run is active."
      break
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

# The base branch may have moved while this run waited.
if [ "$require_up_to_date" = "true" ]; then
  behind=$(gh api "repos/$GITHUB_REPOSITORY/compare/$BASE_REF...$HEAD_SHA" --jq .behind_by)
  if [ "$behind" -gt 0 ]; then
    echo "::error::Branch is $behind commit(s) behind $BASE_REF. Update the branch to run the tests."
    exit 1
  fi
  echo "Branch is up to date with $BASE_REF."
fi
