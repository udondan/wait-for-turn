# shellcheck shell=bash
# jq programs and scripts for later are in single quotes on purpose.
# shellcheck disable=SC2016
#
# State of the fake GitHub API in $FAKE_STATE, shared by the tests, the fake
# gh and the scripts that run while wait.sh sleeps.
#
#   runs.json      workflow runs of the queued workflow
#   pulls.json     pull requests
#   compare/<sha>  commits <sha> is behind main, 0 if missing
#   commits/<sha>  message of a commit created through the API
#   refs/<ref>     sha of a ref, without the refs/ prefix
#   fail           "<http code> <regex>" lines, matching API calls fail
#   hook           script run before every API call with method and path
#   ticks/<n>      script run during the nth sleep
#   calls.log      API calls and sleeps
#   statuses.log   "<state>|<description>" of every commit status set

FAKE_WORKFLOW=test.yml

# Writes the result of a jq program over a state file back to the file.
json_edit() {
  local file=$FAKE_STATE/$1 out
  shift
  out=$(jq "$@" "$file")
  printf '%s\n' "$out" >"$file"
}

# Stores a commit with the message $1 and prints its sha.
new_commit() {
  local n sha
  n=$(($(cat "$FAKE_STATE/commit-count" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$FAKE_STATE/commit-count"
  sha=$(printf 'c%039d' "$n")
  printf '%s' "$1" >"$FAKE_STATE/commits/$sha"
  echo "$sha"
}

# add_run <id> [pr] [started hh:mm] [status] [conclusion] [head sha]
# The head sha defaults to the pull request's head sha.
add_run() {
  local id=$1 pr=${2:-} started=${3:-00:00} status=${4:-in_progress} conclusion=${5:-} head=${6:-}
  [ -n "$head" ] || head=head${pr:-$id}
  json_edit runs.json --argjson id "$id" --arg pr "$pr" --arg started "$started" \
    --arg status "$status" --arg conclusion "$conclusion" --arg head "$head" '
    . + [{id: $id, status: $status,
      conclusion: (if $conclusion == "" then null else $conclusion end),
      head_sha: $head, run_started_at: "2026-01-01T\($started):00Z",
      html_url: "https://github.com/owner/repo/actions/runs/\($id)",
      pull_requests: (if $pr == "" then [] else [{number: ($pr | tonumber)}] end)}]'
}

# complete_run <id> [conclusion]
complete_run() {
  json_edit runs.json --argjson id "$1" --arg c "${2:-success}" \
    'map(if .id == $id then .status = "completed" | .conclusion = $c else . end)'
}

# add_pr <number> [labels, comma separated] [auto-merge true|false]
# The head sha is head<number>.
add_pr() {
  json_edit pulls.json --argjson n "$1" --arg labels "${2:-}" --argjson auto "${3:-false}" '
    . + [{number: $n, state: "open",
      labels: ($labels | split(",") | map(select(. != "") | {name: .})),
      auto_merge: (if $auto then {merge_method: "squash"} else null end),
      head: {sha: "head\($n)", repo: {full_name: "owner/repo"}}, base: {ref: "main"},
      mergeable_state: "clean"}]'
}

# set_pr <number> <jq expression applied to the pull request>
set_pr() {
  json_edit pulls.json --argjson n "$1" "map(if .number == \$n then ($2) else . end)"
}

# set_behind <sha> <commits behind main>
set_behind() {
  echo "$2" >"$FAKE_STATE/compare/$1"
}

# fail_api <http code> <regex on "METHOD path">
# Path is without repos/owner/repo/, e.g. "GET actions/runs/200". Calls with a
# query are matched without and with it, e.g. "GET pulls?state=open".
# "PR update-branch" matches gh pr update-branch.
fail_api() {
  echo "$1 $2" >>"$FAKE_STATE/fail"
}

lock_dir() {
  echo "$FAKE_STATE/refs/wait-for-turn/$FAKE_WORKFLOW"
}

# hold_lock <n> <run id> [pr]: creates lock ref n of another run.
hold_lock() {
  local message="wait-for-turn: run $2"
  [ -z "${3:-}" ] || message="$message, pull request $3"
  mkdir -p "$(lock_dir)"
  new_commit "$message" >"$(lock_dir)/$1"
}

# Prints the numbers of the lock refs, sorted.
lock_refs() {
  [ -d "$(lock_dir)" ] || return 0
  find "$(lock_dir)" -type f -exec basename {} \; | sort -n
}

# Prints the message of the commit of lock ref n.
lock_message() {
  cat "$FAKE_STATE/commits/$(cat "$(lock_dir)/$1")"
}

# at_tick <n> <bash code>: runs the code during the nth sleep of wait.sh.
at_tick() {
  local file=$FAKE_STATE/ticks/$1
  [ -f "$file" ] || echo 'source "$FAKE_LIB/state.bash"' >"$file"
  echo "$2" >>"$file"
}

# stop_at_tick <n>: wait.sh exits with 99 in its nth sleep.
stop_at_tick() {
  at_tick "$1" 'touch "$FAKE_STATE/stop"'
}

# on_api <bash code>: runs the code before every API call, with the method in
# $1 and the path in $2.
on_api() {
  printf '%s\n%s\n' 'source "$FAKE_LIB/state.bash"' "$1" >"$FAKE_STATE/hook"
}
