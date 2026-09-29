#!/usr/bin/env bash
# Waits for the turn of this run among the active runs of the same workflow.
#
# The turn is held by the run that created the newest lock ref
# refs/wait-for-turn/<workflow>/<n>. It is released when that run completes.
# The next run takes the turn by creating ref <n+1>. Creating a ref fails if it
# already exists, so only one run can take the turn.
#
# Waiting runs are ordered by the summed weight of their pull request labels
# (highest first), then by start time. Only the first waiting run takes the
# turn. It checks often, the others check less often to save API requests.
#
# The status filter of the list-runs API (?status=in_progress) is backed by a
# search index that can be stale and return no runs although runs are active.
# The unfiltered list is correct, so active runs are filtered client-side.
set -euo pipefail

workflow="${INPUT_WORKFLOW:-}"
if [ -z "$workflow" ]; then
  # GITHUB_WORKFLOW_REF: owner/repo/.github/workflows/file.yml@refs/...
  workflow_path="${GITHUB_WORKFLOW_REF%%@*}"
  workflow="${workflow_path##*/}"
fi
interval="${INPUT_POLL_INTERVAL:-30}"
queued_interval="${INPUT_QUEUED_POLL_INTERVAL:-300}"
timeout_minutes="${INPUT_TIMEOUT_MINUTES:-0}"
require_up_to_date="${INPUT_REQUIRE_UP_TO_DATE:-false}"
repo="repos/$GITHUB_REPOSITORY"
lock_prefix="wait-for-turn/$workflow"

if [ "$require_up_to_date" = "true" ] && { [ -z "${BASE_REF:-}" ] || [ -z "${HEAD_SHA:-}" ]; }; then
  echo "::notice::require-up-to-date only applies to pull_request events, skipping the check."
  require_up_to_date=false
fi

# label-weights: one "label=weight" per line, e.g. "renovate=-5".
weights=$(printf '%s\n' "${INPUT_LABEL_WEIGHTS:-}" | jq -R -s '
  split("\n") | map(sub("^\\s+"; "") | sub("\\s+$"; "")) | map(select(length > 0))
  | map(capture("^(?<label>.+?)\\s*=\\s*(?<weight>[+-]?[0-9]+)$")
        // error("Invalid label-weights line: \(.). Expected label=weight."))
  | map({(.label): (.weight | tonumber)}) | add // {}')

# Fails the run if the branch is behind the base branch. Testing an outdated
# branch is wasted time: it has to be updated and tested again anyway.
# With "strict", a failing API request fails the run as well.
check_up_to_date() {
  [ "$require_up_to_date" = "true" ] || return 0
  local behind
  if ! behind=$(gh api "$repo/compare/$BASE_REF...$HEAD_SHA" --jq .behind_by); then
    if [ "${1:-}" = "strict" ]; then
      echo "::error::Comparing with $BASE_REF failed."
      exit 1
    fi
    echo "Comparing with $BASE_REF failed, retrying later."
    return 0
  fi
  if [ "$behind" -gt 0 ]; then
    echo "::error::Branch is $behind commit(s) behind $BASE_REF. Update the branch to run the tests."
    exit 1
  fi
}

# Prints "<n> <commit sha>" of all lock refs, sorted by n.
list_locks() {
  gh api --paginate "$repo/git/matching-refs/$lock_prefix/" \
    --jq ".[] | (.ref | ltrimstr(\"refs/$lock_prefix/\")) as \$n
      | select(\$n | test(\"^[0-9]+$\")) | \"\(\$n) \(.object.sha)\"" | sort -n
}

# Run ids of lock commits, by commit sha. Lock commits never change.
# Sets holder to the run id of the lock commit.
declare -A lock_runs=()
read_holder() {
  local sha=$1
  if [ -z "${lock_runs[$sha]:-}" ]; then
    lock_runs[$sha]=$(gh api "$repo/git/commits/$sha" --jq '.message | capture("run (?<id>[0-9]+)").id')
  fi
  holder=${lock_runs[$sha]}
}

# Holder runs known to have completed.
declare -A completed_runs=()
is_active() {
  local id=$1
  [ -z "${completed_runs[$id]:-}" ] || return 1
  if echo "$active" | jq -e --argjson id "$id" 'any(.[]; .id == $id)' >/dev/null; then
    return 0
  fi
  # Not in the list of recent active runs. Ask for the run itself before
  # releasing its turn.
  # Only a missing run counts as completed, other errors keep the turn held.
  local status
  if ! status=$(gh api "$repo/actions/runs/$id" --jq .status 2>&1); then
    [[ "$status" == *"HTTP 404"* ]] || return 0
    status=completed
  fi
  if [ "$status" != "completed" ]; then
    return 0
  fi
  completed_runs[$id]=1
  return 1
}

tree=""
# Tries to take the turn by creating lock ref n. Returns 1 if another run was
# faster.
take_turn() {
  local n=$1 commit out
  if [ -z "$tree" ]; then
    tree=$(gh api "$repo/git/commits/$GITHUB_SHA" --jq .tree.sha) || return 1
  fi
  commit=$(gh api "$repo/git/commits" -f message="wait-for-turn: run $GITHUB_RUN_ID" -f tree="$tree" --jq .sha) || return 1
  if ! out=$(gh api "$repo/git/refs" -f ref="refs/$lock_prefix/$n" -f sha="$commit" --silent 2>&1); then
    if [[ "$out" == *"HTTP 422"* ]]; then
      return 1
    fi
    echo "::error::Creating lock ref refs/$lock_prefix/$n failed: $out"
    echo "::error::The token needs contents: write permission."
    exit 1
  fi
  # A run that saw an older lock may have recreated an old, already deleted ref
  # number. The newest ref wins.
  local newest
  newest=$(list_locks | tail -n 1 | cut -d ' ' -f 1)
  if [ "$newest" != "$n" ]; then
    gh api -X DELETE "$repo/git/refs/$lock_prefix/$n" --silent || true
    return 1
  fi
  # Remove released locks.
  local old _
  list_locks | while read -r old _; do
    if [ "$old" -lt "$n" ]; then
      gh api -X DELETE "$repo/git/refs/$lock_prefix/$old" --silent || true
    fi
  done
  return 0
}

runs_url="$repo/actions/workflows/$workflow/runs?per_page=100"
runs_query='[.workflow_runs[] | select(.status != "completed")
  | {id, run_started_at, html_url, pr: (.pull_requests[0].number // null)}]'
prs='[]'
next_refresh=0
last_state=""

deadline=0
if [ "$timeout_minutes" -gt 0 ]; then
  deadline=$((SECONDS + timeout_minutes * 60))
fi

while true; do
  sleep_for=$queued_interval
  if ! active=$(gh api "$runs_url" --jq "$runs_query") || ! locks=$(list_locks); then
    echo "Listing runs or locks failed, retrying."
    sleep_for=$interval
  else
    holder=""
    newest=0
    if [ -n "$locks" ]; then
      read -r newest sha <<<"$(echo "$locks" | tail -n 1)"
      read_holder "$sha"
    fi
    if [ "$holder" = "$GITHUB_RUN_ID" ]; then
      # A re-run of the holder keeps the turn.
      echo "This run already has the turn."
      break
    fi
    free=true
    if [ -n "$holder" ] && is_active "$holder"; then
      free=false
    fi

    if [ "$SECONDS" -ge "$next_refresh" ] || [ "$free" = "true" ]; then
      check_up_to_date
      if new_prs=$(gh api --paginate "$repo/pulls?state=open&per_page=100" \
          --jq '.[] | {number, labels: [.labels[].name]}' | jq -s .); then
        prs=$new_prs
      else
        echo "Listing pull requests failed, using the last known labels."
      fi
      next_refresh=$((SECONDS + queued_interval))
    fi

    queue=$(jq -n --argjson runs "$active" --argjson prs "$prs" --argjson w "$weights" --arg holder "$holder" '
      ($prs | map({key: (.number | tostring), value: ([.labels[] | $w[.] // 0] | add // 0)}) | from_entries) as $pw
      | $runs | map(select((.id | tostring) != $holder) | . + {weight: ($pw[.pr | tostring] // 0)})
      | sort_by(-.weight, .run_started_at, .id)')
    position=$(echo "$queue" | jq --argjson id "$GITHUB_RUN_ID" 'map(.id) | index($id) // -1')

    if [ "$free" = "true" ] && [ "$position" = "0" ]; then
      check_up_to_date strict
      if take_turn $((newest + 1)); then
        echo "Took the turn."
        break
      fi
      echo "Could not take the turn, another run may have been faster. Retrying."
      sleep "$interval"
      continue
    fi

    if [ "$position" = "0" ]; then
      sleep_for=$interval
    fi
    if [ "$position" = "-1" ]; then
      state="This run is not in the list of active runs yet."
    else
      state=$(echo "$queue" | jq -r --argjson pos "$position" '
        "Position \($pos + 1) of \(length) (weight \(.[$pos].weight)). Queue: "
        + (map("\(.html_url) (weight \(.weight))") | join(", "))')
      if [ "$free" = "true" ]; then
        state="$state. The turn is free, waiting for the first run to take it."
      else
        state="$state. Turn held by run $holder."
      fi
    fi
    if [ "$state" != "$last_state" ]; then
      echo "$state"
      last_state=$state
    fi
  fi
  if [ "$deadline" -gt 0 ] && [ "$SECONDS" -ge "$deadline" ]; then
    echo "::error::Timed out after $timeout_minutes minutes waiting for the turn."
    exit 1
  fi
  sleep "$sleep_for"
done

if [ "$require_up_to_date" = "true" ]; then
  echo "Branch is up to date with $BASE_REF."
fi
