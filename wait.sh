#!/usr/bin/env bash
# Waits for the turn of this run among the active runs of the same workflow.
#
# The turn is held by the run that created the newest lock ref
# refs/wait-for-turn/<workflow>/<n>. It is released when that run completes.
# The next run takes the turn by creating ref <n+1>. Creating a ref fails if it
# already exists, so only one run can take the turn.
#
# Waiting runs are ordered by the summed weight of their pull request labels
# (highest first), then by start time. Runs without a pull request, for example
# of a push to main, have the weight no-pull-request-weight. A run of a pull request that has a newer
# run is left out. Only the first waiting run takes the turn. It checks often,
# the others check less often to save API requests, except while the turn is
# free: the first run may never take it.
#
# When the holder succeeded and its pull request has auto-merge enabled, the
# pull request is merged a few seconds after the run completes. A run taking the
# turn in between would test a branch that is outdated right after. The turn
# stays held until the pull request is merged or can't be merged, or a new
# commit was pushed to it: auto-merge waits for the run of the new commit, which
# waits for the turn.
#
# After a merge, the branches of the other pull requests are behind and their
# runs fail as outdated. A pull request updated right away, for example a
# release pull request, would then be the only waiting run and take the turn,
# although the pull requests updated a few minutes later have a higher weight.
# So before taking the turn, a run lets open pull requests with auto-merge
# enabled and a higher weight go first while they are about to be tested.
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
merge_wait="${INPUT_MERGE_WAIT:-10}"
yield_minutes="${INPUT_YIELD_MINUTES:-10}"
no_pr_weight="${INPUT_NO_PR_WEIGHT:-0}"
if ! [[ "$no_pr_weight" =~ ^-?(0|[1-9][0-9]*)$ ]]; then
  echo "::error::Invalid no-pull-request-weight: $no_pr_weight. Expected an integer."
  exit 1
fi
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
    update_branch "$behind"
    echo "::error::Branch is $behind commit(s) behind $BASE_REF. Update the branch to run the tests."
    exit 1
  fi
}

# Rebases the pull request branch onto the base branch with update-token, then
# fails the run: its commit is outdated, the new commit starts a new run.
# Returns without doing anything when no update-token is set or the branch is
# in a fork.
update_branch() {
  local behind=$1 output
  [ -n "${UPDATE_TOKEN:-}" ] || return 0
  if [ "${HEAD_REPO:-}" != "$GITHUB_REPOSITORY" ]; then
    echo "::notice::The branch is in another repository and can't be updated."
    return 0
  fi
  if ! output=$(GH_TOKEN="$UPDATE_TOKEN" gh pr update-branch "$PR_NUMBER" --rebase -R "$GITHUB_REPOSITORY" 2>&1); then
    echo "::error::Branch is $behind commit(s) behind $BASE_REF and rebasing it failed: $output"
    exit 1
  fi
  echo "::notice::Branch was $behind commit(s) behind $BASE_REF and was rebased. The new commit starts a new run."
  exit 1
}

# Prints "<n> <commit sha>" of all lock refs, sorted by n.
list_locks() {
  gh api --paginate "$repo/git/matching-refs/$lock_prefix/" \
    --jq ".[] | (.ref | ltrimstr(\"refs/$lock_prefix/\")) as \$n
      | select(\$n | test(\"^[0-9]+$\")) | \"\(\$n) \(.object.sha)\"" | sort -n
}

# Run ids and pull request numbers of lock commits, by commit sha. Lock commits
# never change. Sets holder to the run id and holder_pr to the pull request
# number of the lock commit. Lock commits of runs without a pull request, and
# of older versions, have no pull request number.
declare -A lock_runs=() lock_prs=()
read_holder() {
  local sha=$1 message
  if [ -z "${lock_runs[$sha]:-}" ]; then
    message=$(gh api "$repo/git/commits/$sha" --jq .message)
    lock_runs[$sha]=$(jq -rn --arg m "$message" '$m | capture("run (?<id>[0-9]+)").id')
    lock_prs[$sha]=$(jq -rn --arg m "$message" '$m | capture("pull request (?<pr>[0-9]+)").pr // ""')
  fi
  holder=${lock_runs[$sha]}
  holder_pr=${lock_prs[$sha]}
}

# Conclusions and head commits of holder runs known to have completed, by run
# id.
declare -A completed_runs=() completed_shas=()
is_active() {
  local id=$1
  [ -z "${completed_runs[$id]:-}" ] || return 1
  if echo "$active" | jq -e --argjson id "$id" 'any(.[]; .id == $id)' >/dev/null; then
    return 0
  fi
  # Not in the list of recent active runs. Ask for the run itself before
  # releasing its turn.
  # Only a missing run counts as completed, other errors keep the turn held.
  local run status conclusion head_sha
  if ! run=$(gh api "$repo/actions/runs/$id" --jq '"\(.status) \(.conclusion) \(.head_sha)"' 2>&1); then
    [[ "$run" == *"HTTP 404"* ]] || return 0
    run="completed missing"
  fi
  read -r status conclusion head_sha <<<"$run"
  if [ "$status" != "completed" ]; then
    return 0
  fi
  completed_runs[$id]=$conclusion
  completed_shas[$id]=${head_sha:-}
  return 1
}

# Returns 0 while the pull request of a completed holder run is about to be
# merged: the run succeeded, it tested the current head commit, and the pull
# request is open with auto-merge enabled. Gives up after merge_wait minutes,
# for example when other required checks fail and auto-merge never merges.
declare -A merge_deadlines=()
merge_pending() {
  local id=$1 pr=$2 pull head_sha
  [ -n "$pr" ] && [ "$merge_wait" -gt 0 ] || return 1
  [ "${completed_runs[$id]:-}" = "success" ] || return 1
  if [ -z "${merge_deadlines[$id]:-}" ]; then
    merge_deadlines[$id]=$((SECONDS + merge_wait * 60))
  fi
  if [ "$SECONDS" -ge "${merge_deadlines[$id]}" ]; then
    return 1
  fi
  if ! pull=$(gh api "$repo/pulls/$pr" --jq '"\(.state) \(.auto_merge != null) \(.mergeable_state) \(.head.sha)"'); then
    echo "Reading pull request #$pr failed, retrying."
    return 0
  fi
  head_sha=${pull##* }
  pull=${pull% *}
  # A new commit was pushed after the holder run started. Auto-merge waits for
  # the run of the new commit, which may be waiting for this turn.
  if [ -n "${completed_shas[$id]:-}" ] && [ "$head_sha" != "${completed_shas[$id]}" ]; then
    return 1
  fi
  case $pull in
    # A branch that is behind or has conflicts is not merged until it is
    # updated, which starts a new run.
    "open true behind" | "open true dirty") return 1 ;;
    "open true "*) return 0 ;;
  esac
  return 1
}

# States of pull request head commits. "behind" when the branch is behind its
# base branch and about to be updated, which doesn't change for a commit.
# "tested" when the commit has a run of this workflow, checked again after
# queued_interval as the base branch may have moved on.
declare -A head_states=() head_checked=()
# Sets pending to the open pull requests with auto-merge enabled and a weight
# higher than $1 that have no active run but are about to be tested: their
# branch is behind and about to be updated, or their head commit has no run of
# this workflow yet. Pull requests whose head commit was tested, successfully
# or not, are not pending.
find_pending() {
  local weight=$1 number sha base behind count
  pending=""
  while read -r number sha base; do
    if [ "${head_states[$sha]:-}" != "behind" ] &&
      { [ "${head_states[$sha]:-}" != "tested" ] || [ "$SECONDS" -ge "$((head_checked[$sha] + queued_interval))" ]; }; then
      unset "head_states[$sha]"
      if ! behind=$(gh api "$repo/compare/$base...$sha" --jq .behind_by </dev/null); then
        # Unknown counts as pending, the wait is limited anyway.
        pending="$pending #$number"
        continue
      fi
      if [ "$behind" -gt 0 ]; then
        head_states[$sha]=behind
      elif count=$(gh api "$repo/actions/workflows/$workflow/runs?head_sha=$sha&per_page=1" --jq .total_count </dev/null) &&
        [ "$count" -gt 0 ]; then
        head_states[$sha]=tested
        head_checked[$sha]=$SECONDS
      fi
    fi
    if [ "${head_states[$sha]:-}" != "tested" ]; then
      pending="$pending #$number"
    fi
  done < <(echo "$prs" | jq -r --argjson w "$weights" --argjson weight "$weight" \
    --argjson runs "$active" --arg self "${PR_NUMBER:-}" '
    .[] | select(.auto_merge and (.number | tostring) != $self)
    | select(.number as $n | all($runs[]; .pr != $n))
    | select(([.labels[] | $w[.] // 0] | add // 0) > $weight)
    | "\(.number) \(.sha) \(.base)"')
  pending=${pending# }
}

# Returns 0 while this run lets pending pull requests with a higher weight go
# first. Gives up yield_minutes after it started, for example when a branch is
# never updated.
yield_deadline=0
yielding() {
  [ "$yield_minutes" -gt 0 ] || return 1
  if [ "$yield_deadline" -gt 0 ] && [ "$SECONDS" -ge "$yield_deadline" ]; then
    return 1
  fi
  find_pending "$1"
  [ -n "$pending" ] || return 1
  if [ "$yield_deadline" -eq 0 ]; then
    yield_deadline=$((SECONDS + yield_minutes * 60))
  fi
  return 0
}

tree=""
# Tries to take the turn by creating lock ref n. Returns 1 if another run was
# faster.
take_turn() {
  local n=$1 commit out
  if [ -z "$tree" ]; then
    tree=$(gh api "$repo/git/commits/$GITHUB_SHA" --jq .tree.sha) || return 1
  fi
  local message="wait-for-turn: run $GITHUB_RUN_ID"
  if [ -n "${PR_NUMBER:-}" ]; then
    message="$message, pull request $PR_NUMBER"
  fi
  commit=$(gh api "$repo/git/commits" -f message="$message" -f tree="$tree" --jq .sha) || return 1
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
    holder_pr=""
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
    held="Turn held by run $holder."
    if [ -n "$holder" ]; then
      if is_active "$holder"; then
        free=false
      elif merge_pending "$holder" "$holder_pr"; then
        free=false
        held="Run $holder completed, waiting for its pull request #$holder_pr to be merged."
      fi
    fi

    if [ "$SECONDS" -ge "$next_refresh" ] || [ "$free" = "true" ]; then
      check_up_to_date
      if new_prs=$(gh api --paginate "$repo/pulls?state=open&per_page=100" \
          --jq '.[] | {number, labels: [.labels[].name], auto_merge: (.auto_merge != null),
            sha: .head.sha, base: .base.ref}' | jq -s .); then
        prs=$new_prs
      else
        echo "Listing pull requests failed, using the last known labels."
      fi
      next_refresh=$((SECONDS + queued_interval))
    fi

    # A run of a pull request that has a newer run is left out: its commit is
    # outdated, and it may still be active although it will never take the
    # turn, for example while other jobs finish after it failed as outdated.
    # This run always stays in the queue.
    queue=$(jq -n --argjson runs "$active" --argjson prs "$prs" --argjson w "$weights" --arg holder "$holder" \
      --argjson self "$GITHUB_RUN_ID" --argjson nopr "$no_pr_weight" '
      ($prs | map({key: (.number | tostring), value: ([.labels[] | $w[.] // 0] | add // 0)}) | from_entries) as $pw
      | ($runs | map(select(.pr != null)) | group_by(.pr)
        | map({key: (.[0].pr | tostring), value: (map(.id) | max)}) | from_entries) as $newest
      | $runs | map(select((.id | tostring) != $holder)
        | select(.id == $self or .pr == null or $newest[.pr | tostring] == .id)
        | . + {weight: (if .pr == null then $nopr else ($pw[.pr | tostring] // 0) end)})
      | sort_by(-.weight, .run_started_at, .id)')
    position=$(echo "$queue" | jq --argjson id "$GITHUB_RUN_ID" 'map(.id) | index($id) // -1')

    if [ "$free" = "true" ] && [ "$position" = "0" ] && yielding "$(echo "$queue" | jq '.[0].weight')"; then
      free=false
      held="Letting pull requests with a higher weight go first, they are about to be tested: $pending."
    fi

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

    # The first run checks often. While the turn is free, so do all others: the
    # first run may never take it, for example when it fails as outdated.
    if [ "$position" = "0" ] || [ "$free" = "true" ]; then
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
        state="$state. $held"
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
