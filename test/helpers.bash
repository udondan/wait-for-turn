# shellcheck shell=bash
# Setup and assertions for the bats tests of wait.sh.
# output and status are set by bats' run.
# shellcheck disable=SC2154

setup() {
  export FAKE_LIB="$BATS_TEST_DIRNAME/lib"
  export FAKE_STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$FAKE_STATE/commits" "$FAKE_STATE/compare" "$FAKE_STATE/refs" "$FAKE_STATE/ticks"
  echo '[]' >"$FAKE_STATE/runs.json"
  echo '[]' >"$FAKE_STATE/pulls.json"
  touch "$FAKE_STATE/calls.log" "$FAKE_STATE/statuses.log"
  PATH="$BATS_TEST_DIRNAME/bin:$PATH"

  # What action.yml sets for a pull_request run of pull request 1.
  export GH_TOKEN=token
  export GITHUB_REPOSITORY=owner/repo
  export GITHUB_RUN_ID=100
  export GITHUB_SHA=merge1
  export GITHUB_SERVER_URL=https://github.com
  export GITHUB_WORKFLOW_REF="owner/repo/.github/workflows/test.yml@refs/pull/1/merge"
  export INPUT_WORKFLOW=""
  export INPUT_LABEL_WEIGHTS=""
  export INPUT_NO_PR_WEIGHT=0
  export INPUT_POLL_INTERVAL=30
  export INPUT_QUEUED_POLL_INTERVAL=300
  export INPUT_TIMEOUT_MINUTES=0
  export INPUT_REQUIRE_UP_TO_DATE=false
  export INPUT_MERGE_WAIT=10
  export INPUT_YIELD_MINUTES=10
  export INPUT_STATUS_CONTEXT=wait-for-turn
  export PR_NUMBER=1
  export BASE_REF=main
  export HEAD_SHA=head1
  export HEAD_REPO=owner/repo
  export UPDATE_TOKEN=""

  # shellcheck source=test/lib/state.bash
  source "$FAKE_LIB/state.bash"
  # This run, of pull request 1.
  add_run 100 1 00:10
  add_pr 1
}

teardown() {
  if grep -q UNHANDLED "$FAKE_STATE/calls.log"; then
    echo "wait.sh made calls the fake gh doesn't know:"
    grep UNHANDLED "$FAKE_STATE/calls.log"
    return 1
  fi
}

# Runs wait.sh with the fake gh and the fake sleep. Under test/coverage.sh,
# wait.sh (and only wait.sh, `-x` is not passed on to child processes) is
# traced for bashcov.
run_wait() {
  local trace=()
  if [[ -n ${WAIT_FOR_TURN_COVERAGE:-} ]]; then
    trace=(-x)
  fi
  run env BASH_ENV="$FAKE_LIB/fake-sleep.bash" bash ${trace[@]+"${trace[@]}"} "$BATS_TEST_DIRNAME/../wait.sh"
}

show_output() {
  echo "--- exit code $status, output:"
  echo "$output"
}

assert_status() {
  [ "$status" -eq "$1" ] || { echo "expected exit code $1"; show_output; return 1; }
}

assert_output_contains() {
  [[ "$output" == *"$1"* ]] || { echo "expected output to contain: $1"; show_output; return 1; }
}

refute_output_contains() {
  [[ "$output" != *"$1"* ]] || { echo "expected output not to contain: $1"; show_output; return 1; }
}

# assert_locks <n>...: the lock refs that exist.
assert_locks() {
  local actual
  actual=$(lock_refs | xargs)
  [ "$actual" = "$*" ] || { echo "expected lock refs '$*', got '$actual'"; show_output; return 1; }
}

# Asserts this run holds lock ref n.
assert_holds() {
  local message
  message=$(lock_message "$1")
  [[ "$message" == "wait-for-turn: run $GITHUB_RUN_ID"* ]] || {
    echo "expected lock $1 to be held by run $GITHUB_RUN_ID, its message is: $message"
    show_output
    return 1
  }
}

# Asserts that the last commit status is "<state>|<description>".
assert_last_commit_status() {
  local last
  last=$(tail -n 1 "$FAKE_STATE/statuses.log")
  [ "$last" = "$1" ] || { echo "expected last commit status '$1', got '$last'"; show_output; return 1; }
}

# Prints how many lines of calls.log match the regex.
count_calls() {
  grep -cE "$1" "$FAKE_STATE/calls.log" || true
}
