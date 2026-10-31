#!/usr/bin/env bash
# Helpers for the end-to-end scenarios. Sourced by setup.sh and scenarios/*.sh.
# Everything talks to the test repository through `gh`, as the logged in user:
# pushes made that way start workflow runs, like those of Renovate would.
# shellcheck disable=SC2016 # jq variables in single quotes
set -euo pipefail

E2E_REPO=${E2E_REPO:-udondan/wait-for-turn-e2e}
E2E_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
R="repos/$E2E_REPO"
WORKFLOW=pipeline.yml

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

# Settings of the test pipeline, see template/.github/workflows/pipeline.yml.
# reset sets these, scenarios override some with configure.
DEFAULT_VARS=(
  POLL=10
  QUEUED_POLL=30
  TIMEOUT=60
  REQUIRE_UP_TO_DATE=true
  USE_UPDATE_TOKEN=false
  MERGE_WAIT=10
  YIELD=10
  UPDATE_PENDING=false
  NO_PR_WEIGHT=-100
  TEST_MAIN=false
  NOSTATUS=false
  DEPLOY_SECONDS=60
)
DEFAULT_LABEL_WEIGHTS='urgent=10
autorelease: pending=-10
renovate=-5'

declare -A current_vars=()
load_vars() {
  local name value
  current_vars=()
  while IFS=$'\t' read -r name value; do
    current_vars[$name]=$value
  done < <(gh api --paginate "$R/actions/variables?per_page=30" --jq '.variables[] | "\(.name)\t\(.value | gsub("\n"; "\\n"))"')
}

# configure NAME=value ... sets repository variables that differ from their
# current value. They apply to runs that start afterwards.
configure() {
  local pair name value
  [ "${#current_vars[@]}" -gt 0 ] || load_vars
  for pair in "$@"; do
    name=${pair%%=*}
    value=${pair#*=}
    if [ "${current_vars[$name]:-}" != "${value//$'\n'/\\n}" ]; then
      gh variable set "$name" -R "$E2E_REPO" --body "$value"
      current_vars[$name]=${value//$'\n'/\\n}
      log "set $name=${value//$'\n'/, }"
    fi
  done
}

main_sha() { gh api "$R/git/ref/heads/main" --jq .object.sha; }

create_branch() {
  gh api "$R/git/refs" -f ref="refs/heads/$1" -f sha="$(main_sha)" --silent
}

# put_file <branch> <path> <content> <message>: commits a file to a branch.
put_file() {
  local branch=$1 path=$2 content=$3 message=$4 blob
  local args=(-X PUT "$R/contents/$path" -f message="$message" -f branch="$branch")
  blob=$(gh api "$R/contents/$path?ref=$branch" --jq .sha 2>/dev/null || true)
  if [ -n "$blob" ]; then
    args+=(-f sha="$blob")
  fi
  args+=(-f content="$(printf '%s' "$content" | base64 | tr -d '\n')")
  gh api "${args[@]}" --jq .commit.sha
}

# file_content <path> <branch>: current content, empty if missing.
file_content() {
  gh api "$R/contents/$1?ref=$2" --jq .content 2>/dev/null | base64 --decode 2>/dev/null || true
}

# bump_file <branch> <path>: changes the file on the branch, the way the kind
# of pull request would: a version bump for deps/*.json, a changelog entry for
# CHANGELOG.md, a random line otherwise.
bump_file() {
  local branch=$1 path=$2 content
  case $path in
    deps/*.json)
      local name=${path##*/}
      content=$(printf '{\n  "name": "%s",\n  "version": "1.%s.0"\n}\n' "${name%.json}" "$RANDOM")
      ;;
    CHANGELOG.md)
      content="$(file_content "$path" "$branch")
- entry $RANDOM"
      ;;
    *)
      content="$RANDOM $(date -u +%FT%TZ)"
      ;;
  esac
  # With SKIP_CI=true the commit starts no workflow run.
  put_file "$branch" "$path" "$content" "chore: update $path${SKIP_CI:+ [skip ci]}"
}

# open_pr <branch> <path> <title> [label ...]: creates the branch, changes the
# file and opens a pull request. Prints its number. EXTRA_FILE=<path> also adds
# that file first, for example fail-deploy.
open_pr() {
  local branch=$1 path=$2 title=$3 url label
  shift 3
  local args=()
  for label in "$@"; do
    args+=(--label "$label")
  done
  create_branch "$branch"
  if [ -n "${EXTRA_FILE:-}" ]; then
    SKIP_CI=true put_file "$branch" "$EXTRA_FILE" "e2e" "chore: add $EXTRA_FILE [skip ci]" >/dev/null
  fi
  bump_file "$branch" "$path" >/dev/null
  url=$(gh pr create -R "$E2E_REPO" --head "$branch" --base main --title "$title" --body "wait-for-turn e2e" "${args[@]}")
  log "opened #${url##*/} ($title${*:+, $*})"
  echo "${url##*/}"
}

# Pull requests like the ones of Renovate, a person and release-please.
renovate_pr() { open_pr "renovate/dep-$1-$RANDOM" "deps/dep-$1.json" "chore(deps): update dep-$1" renovate; }
plain_pr() { open_pr "feature/$1-$RANDOM" "notes/$1.txt" "feat: $1" "${@:2}"; }
release_pr() { open_pr "release-please--branches--main" CHANGELOG.md "chore(main): release" "autorelease: pending"; }

auto_merge() {
  gh pr merge "$1" --auto --squash -R "$E2E_REPO" >/dev/null
  log "enabled auto-merge on #$1"
}
add_label() {
  gh pr edit "$1" --add-label "$2" -R "$E2E_REPO" >/dev/null
  log "labelled #$1 $2"
}
pr_branch() { gh pr view "$1" -R "$E2E_REPO" --json headRefName --jq .headRefName; }
head_sha() { gh pr view "$1" -R "$E2E_REPO" --json headRefOid --jq .headRefOid; }
pr_state() { gh pr view "$1" -R "$E2E_REPO" --json state --jq .state; }

# push_commit <pr>: pushes a new commit to the pull request branch.
push_commit() {
  bump_file "$(pr_branch "$1")" "notes/push-$1.txt" >/dev/null
  log "pushed a commit to #$1"
}
rebase_pr() {
  gh pr update-branch "$1" --rebase -R "$E2E_REPO" >/dev/null
  log "rebased #$1"
}

# Newest lock ref of the pipeline: "<run id> <pull request>".
holder() {
  local sha
  sha=$(gh api "$R/git/matching-refs/wait-for-turn/$WORKFLOW/" --jq 'map(.ref | split("/") | last | tonumber) as $n | .[] | select((.ref | split("/") | last | tonumber) == ($n | max)) | .object.sha')
  [ -n "$sha" ] || return 0
  gh api "$R/git/commits/$sha" --jq '.message | [capture("run (?<id>[0-9]+)").id, (capture("pull request (?<pr>[0-9]+)").pr // "")] | join(" ")'
}
holder_pr() { holder | cut -s -d ' ' -f 2; }

# Latest wait-for-turn status of the pull request's head commit:
# "<state> <description>".
pr_status() {
  gh api "$R/commits/$(head_sha "$1")/statuses" --jq '[.[] | select(.context == "wait-for-turn")][0] // empty | "\(.state) \(.description)"'
}

# Newest run of the pipeline for the pull request's head commit.
pr_run() {
  gh api "$R/actions/workflows/$WORKFLOW/runs?head_sha=$(head_sha "$1")&per_page=1" --jq '.workflow_runs[0].id // empty'
}
cancel_run() {
  gh run cancel "$1" -R "$E2E_REPO" >/dev/null
  log "cancelled run $1"
}
rerun() {
  gh run rerun "$1" -R "$E2E_REPO" >/dev/null
  log "re-running run $1"
}
run_completed() { [ "$(gh api "$R/actions/runs/$1" --jq .status)" = completed ]; }

active_runs() {
  gh api "$R/actions/runs?per_page=100" --jq '[.workflow_runs[] | select(.status != "completed")] | length'
}

# wait_until <description> <timeout seconds> <command ...>: polls the command
# every 5 seconds until it succeeds.
wait_until() {
  local description=$1 timeout=$2 start=$SECONDS
  shift 2
  log "waiting until $description"
  until "$@" >/dev/null 2>&1; do
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      die "timed out after ${timeout}s waiting until $description"
    fi
    sleep 5
  done
  log "done: $description ($((SECONDS - start))s)"
}
is_holder() { [ "$(holder_pr)" = "$1" ]; }
status_matches() { pr_status "$1" | grep -Eq "$2"; }
no_active_runs() { [ "$(active_runs)" = 0 ]; }

# runs_since_start: number of runs created since the scenario started.
runs_since_start() {
  gh api "$R/actions/runs?per_page=100" --jq "[.workflow_runs[] | select(.created_at >= \"$(cat "$RESULTS/start")\")] | length"
}

# wait_settled <timeout seconds>: waits until runs were started since the
# scenario began and none of them is active for 30 seconds in a row, since
# rebases and new commits start runs a few seconds later.
wait_settled() {
  local timeout=$1 start=$SECONDS quiet=0
  log "waiting until all runs completed"
  while [ "$quiet" -lt 30 ]; do
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      die "timed out after ${timeout}s waiting until all runs completed"
    fi
    sleep 10
    if [ "$(runs_since_start 2>/dev/null)" -gt 0 ] 2>/dev/null && no_active_runs 2>/dev/null; then
      quiet=$((quiet + 10))
    else
      quiet=0
    fi
  done
  log "done: all runs completed ($((SECONDS - start))s)"
}
is_merged() { [ "$(pr_state "$1")" = MERGED ]; }
all_merged() {
  local pr
  for pr in "$@"; do
    is_merged "$pr" || return 1
  done
}

# Closes all pull requests, deletes all branches but main, cancels active runs
# and removes lock and resource refs, then resets the settings.
reset() {
  local pr id branch ref start=$SECONDS
  log "resetting $E2E_REPO"
  for pr in $(gh pr list -R "$E2E_REPO" --state open --json number --jq '.[].number'); do
    gh pr close "$pr" -R "$E2E_REPO" >/dev/null
  done
  while [ "$(active_runs)" != 0 ]; do
    for id in $(gh api "$R/actions/runs?per_page=100" --jq '.workflow_runs[] | select(.status != "completed") | .id'); do
      if [ $((SECONDS - start)) -lt 60 ]; then
        gh api -X POST "$R/actions/runs/$id/cancel" --silent 2>/dev/null || true
      else
        gh api -X POST "$R/actions/runs/$id/force-cancel" --silent 2>/dev/null || true
      fi
    done
    sleep 5
  done
  for branch in $(gh api --paginate "$R/branches?per_page=100" --jq '.[].name | select(. != "main")'); do
    gh api -X DELETE "$R/git/refs/heads/$branch" --silent || true
  done
  for ref in $(gh api "$R/git/matching-refs/wait-for-turn/" --jq '.[].ref') $(gh api "$R/git/matching-refs/e2e-resource/" --jq '.[].ref'); do
    gh api -X DELETE "$R/git/$ref" --silent || true
  done
  configure "${DEFAULT_VARS[@]}" "LABEL_WEIGHTS=$DEFAULT_LABEL_WEIGHTS"
}

# Scenario life cycle: scenario_start <name> resets the repository and starts
# the observer, scenario_finish stops it, collects the runs, jobs and statuses
# and runs the generic checks. The expect_* functions then check the
# scenario's own expectations against the report; scenario_end prints the
# result and exits 1 when anything failed.
scenario_start() {
  SCENARIO=$1
  RESULTS="$E2E_DIR/results/$SCENARIO-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$RESULTS"
  reset
  date -u +%FT%TZ >"$RESULTS/start"
  "$E2E_DIR/observe.sh" "$RESULTS" &
  OBSERVER=$!
  FAILURES=0
  log "scenario $SCENARIO, results in $RESULTS"
}

# Saves the settings the runs used. Called by scenario_finish, since scenarios
# configure after scenario_start.
save_config() {
  load_vars
  local name json='{}'
  for name in "${!current_vars[@]}"; do
    json=$(jq --arg n "$name" --arg v "${current_vars[$name]//\\n/$'\n'}" '. + {($n): $v}' <<<"$json")
  done
  echo "$json" >"$RESULTS/config.json"
}

scenario_finish() {
  kill "$OBSERVER" 2>/dev/null || true
  wait "$OBSERVER" 2>/dev/null || true
  save_config
  log "collecting runs, jobs and statuses"
  "$E2E_DIR/collect.sh" "$RESULTS"
  if ! "$E2E_DIR/analyze.sh" "$RESULTS" "${MAX_GAP:-180}"; then
    FAILURES=$((FAILURES + 1))
  fi
}

report() { jq "$@" "$RESULTS/report.json"; }
check() {
  local name=$1 ok=$2 detail=$3 result=PASS
  if [ "$ok" != true ]; then
    result=FAIL
    FAILURES=$((FAILURES + 1))
  fi
  printf '%s %s: %s\n' "$result" "$name" "$detail" | tee -a "$RESULTS/summary.txt"
}

# expect_turn_order <pr|main> ...: the pull requests (or "main" for a push run)
# took the turn of the pipeline in this order.
expect_turn_order() {
  local actual
  actual=$(report -r '[.turns[] | select(.workflow == "pipeline.yml") | (.pr // "main" | tostring)] | join(" ")')
  check turn-order "$([ "$actual" = "$*" ] && echo true || echo false)" "expected $*, got $actual"
}

# expect_turn_pattern <regex>: like expect_turn_order, for orders that are
# only partly fixed. The turns are joined with spaces.
expect_turn_pattern() {
  local actual
  actual=$(report -r '[.turns[] | select(.workflow == "pipeline.yml") | (.pr // "main" | tostring)] | join(" ")')
  check turn-order "$(echo "$actual" | grep -Eqx "$1" && echo true || echo false)" "expected /$1/, got $actual"
}

# expect_status <pr> <regex>: a wait-for-turn status of one of the pull
# request's runs had a "<state> <description>" matching the regex.
expect_status() {
  local ok
  ok=$(report --arg pr "$1" --arg re "$2" '[.runs[] | select((.pr | tostring) == $pr) | .statuses[] | "\(.state) \(.description)" | test($re)] | any')
  check "status #$1" "$ok" "a status matches /$2/"
}

# expect_final_status <pr> <regex>: the last status of one of the pull
# request's runs matches.
expect_final_status() {
  local ok
  ok=$(report --arg pr "$1" --arg re "$2" '[.runs[] | select((.pr | tostring) == $pr) | .statuses | last // empty | "\(.state) \(.description)" | test($re)] | any')
  check "final status #$1" "$ok" "a run ended with a status matching /$2/"
}

# expect_annotation <pr> <regex>: an annotation of a wait job of the pull
# request matches, for example a warning or error the action logged.
expect_annotation() {
  local ok
  ok=$(report --arg pr "$1" --arg re "$2" '[.runs[] | select((.pr | tostring) == $pr) | .annotations[] | "\(.level) \(.message)" | test($re)] | any')
  check "annotation #$1" "$ok" "an annotation matches /$2/"
}

# expect_jq <name> <detail> [jq options] <expression>: the expression on
# report.json is true.
expect_jq() {
  local name=$1 detail=$2
  shift 2
  check "$name" "$(report "$@")" "$detail"
}

# expect_gap <pr> <min> <max>: seconds between the previous deploy ending and
# the first deploy of the pull request starting.
expect_gap() {
  local gap
  gap=$(report --arg pr "$1" '[.gaps[] | select((.pr | tostring) == $pr) | .gap] | first // "none"')
  check "gap #$1" "$(jq -n --arg g "$gap" --argjson min "$2" --argjson max "$3" '$g != "none" and ($g | tonumber) >= $min and ($g | tonumber) <= $max')" "${gap}s, expected ${2}-${3}s"
}

expect_merged() {
  local pr
  for pr in "$@"; do
    check "merged #$pr" "$(report --arg pr "$pr" '[.prs[] | select((.number | tostring) == $pr) | .merged_at != null] | any')" "#$pr was merged"
  done
}

scenario_end() {
  echo
  if [ "$FAILURES" -gt 0 ]; then
    log "scenario $SCENARIO: $FAILURES check(s) FAILED, see $RESULTS"
    exit 1
  fi
  log "scenario $SCENARIO: all checks passed, see $RESULTS"
}
