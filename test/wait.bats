#!/usr/bin/env bats
# Tests of wait.sh against a fake GitHub API. Every test is run 100 of pull
# request 1, see setup in helpers.bash.
#
# Each test runs in its own subshell, so changing the environment in one test
# doesn't affect the others. Code for later runs is in single quotes on purpose.
# shellcheck disable=SC2030,SC2031,SC2016

load helpers

# Run 200 of pull request 2 holds lock 1 and is still running.
holder_running() {
  add_pr 2
  add_run 200 2 00:05
  hold_lock 1 200 2
}

# Run 200 of pull request 2 holds lock 1 and succeeded. Pull request 2 has
# auto-merge enabled.
holder_succeeded() {
  add_pr 2 "" true
  add_run 200 2 00:05 completed success
  hold_lock 1 200 2
}

# --- Taking the turn ---

@test "takes the turn when it is free" {
  run_wait
  assert_status 0
  assert_locks 1
  [ "$(lock_message 1)" = "wait-for-turn: run 100, pull request 1" ]
  [ "$(head -n 1 "$FAKE_STATE/statuses.log")" = "pending|Waiting for the turn." ]
  assert_last_commit_status "success|Took the turn."
  [ "$(count_calls '^sleep')" -eq 0 ]
}

@test "waits while the holder runs, then takes the next lock and removes the old one" {
  holder_running
  at_tick 2 'complete_run 200 failure'
  run_wait
  assert_status 0
  assert_output_contains "Position 1 of 1 (weight 0)"
  assert_output_contains "Turn held by run 200."
  assert_locks 2
  assert_holds 2
  # First in line, checks often.
  [ "$(count_calls '^sleep 30$')" -eq 2 ]
}

@test "a holder run that doesn't exist anymore releases the turn" {
  hold_lock 1 200 2
  run_wait
  assert_status 0
  assert_locks 2
  assert_holds 2
}

@test "an error reading the holder run keeps the turn held" {
  hold_lock 1 200 2
  fail_api 500 '^GET actions/runs/200$'
  stop_at_tick 1
  run_wait
  assert_status 99
  assert_output_contains "Turn held by run 200."
  assert_locks 1
}

@test "a holder run missing from the list of runs keeps the turn while it runs" {
  hold_lock 1 200 2
  # The run is only found when asked for directly, like a run the list missed.
  on_api '
    [ "$1 $2" = "GET actions/runs/200" ] || exit 0
    rm "$FAKE_STATE/hook"
    add_run 200 2 00:05'
  stop_at_tick 1
  run_wait
  assert_status 99
  assert_output_contains "Turn held by run 200."
  assert_locks 1
}

@test "retries when listing the runs fails" {
  fail_api 500 '^GET actions/workflows/test.yml/runs$'
  at_tick 1 'rm "$FAKE_STATE/fail"'
  run_wait
  assert_status 0
  assert_output_contains "Listing runs or locks failed, retrying."
  [ "$(count_calls '^sleep 30$')" -eq 1 ]
  assert_holds 1
}

@test "waits while this run is not in the list of active runs yet" {
  json_edit runs.json 'map(select(.id != 100))'
  at_tick 1 'add_run 100 1 00:10'
  run_wait
  assert_status 0
  assert_output_contains "This run is not in the list of active runs yet."
  grep -qF "pending|This run is not in the list of active runs yet." "$FAKE_STATE/statuses.log"
  assert_holds 1
}

@test "a re-run of the holder keeps the turn" {
  hold_lock 1 100 1
  run_wait
  assert_status 0
  assert_output_contains "This run already has the turn."
  assert_locks 1
  assert_last_commit_status "success|Took the turn."
}

@test "retries after another run created the same lock first" {
  on_api '
    [ "$1 $2" = "POST git/refs" ] || exit 0
    rm "$FAKE_STATE/hook"
    hold_lock 1 200'
  run_wait
  assert_status 0
  assert_output_contains "Could not take the turn, another run may have been faster."
  assert_locks 2
  assert_holds 2
}

@test "gives the lock back when a newer lock exists" {
  on_api '
    [ "$1 $2" = "POST git/refs" ] || exit 0
    rm "$FAKE_STATE/hook"
    add_run 200 "" 00:00
    hold_lock 2 200'
  at_tick 1 'complete_run 200 failure'
  run_wait
  assert_status 0
  assert_output_contains "Could not take the turn"
  [ "$(count_calls '^DELETE git/refs/wait-for-turn/test.yml/1$')" -eq 1 ]
  assert_locks 3
  assert_holds 3
}

@test "fails when the lock ref can't be created" {
  fail_api 403 '^POST git/refs$'
  run_wait
  assert_status 1
  assert_output_contains "The token needs contents: write permission."
  assert_last_commit_status "failure|Waiting for the turn failed, see the log."
}

# --- Queue order ---

@test "runs that are not first in line check less often" {
  holder_running
  add_pr 3
  add_run 300 3 00:01
  stop_at_tick 1
  run_wait
  assert_status 99
  assert_output_contains "Position 2 of 2 (weight 0)"
  [ "$(count_calls '^sleep 300$')" -eq 1 ]
}

@test "a run with a higher label weight goes first" {
  INPUT_LABEL_WEIGHTS=$'  prio = +5\n\nrenovate=-5  '
  add_pr 2 prio
  add_run 200 2 00:20
  stop_at_tick 1
  run_wait
  assert_status 99
  assert_output_contains "Position 2 of 2 (weight 0)"
  assert_output_contains "runs/200 (weight 5)"
  assert_locks
}

@test "a run with a negative label weight goes last" {
  INPUT_LABEL_WEIGHTS="renovate=-5"
  set_pr 1 '.labels = [{name: "renovate"}]'
  add_pr 2
  add_run 200 2 00:20
  stop_at_tick 1
  run_wait
  assert_status 99
  assert_output_contains "Position 2 of 2 (weight -5)"
}

@test "the weights of all labels add up" {
  INPUT_LABEL_WEIGHTS=$'prio=5\nextra=2\nunused=100'
  add_pr 2 prio,extra,other
  add_run 200 2 00:20
  stop_at_tick 1
  run_wait
  assert_status 99
  assert_output_contains "runs/200 (weight 7)"
}

@test "runs with equal weight go by start time" {
  add_pr 2
  add_run 200 2 00:05
  stop_at_tick 1
  run_wait
  assert_status 99
  assert_output_contains "Position 2 of 2 (weight 0)"
}

@test "a run that started later waits for this one" {
  add_pr 2
  add_run 200 2 00:20
  run_wait
  assert_status 0
  assert_holds 1
}

@test "only the newest run of a pull request is in the queue" {
  add_pr 2
  add_run 90 2 00:01
  add_run 95 2 00:02
  stop_at_tick 1
  run_wait
  assert_status 99
  assert_output_contains "Position 2 of 2"
  refute_output_contains "runs/90 "
}

@test "this run stays in the queue although its pull request has a newer run" {
  add_run 110 1 00:11
  run_wait
  assert_status 0
  assert_holds 1
}

@test "runs without a pull request have the no-pull-request-weight" {
  export PR_NUMBER="" BASE_REF="" HEAD_SHA="" HEAD_REPO=""
  export INPUT_NO_PR_WEIGHT=-1
  echo '[]' >"$FAKE_STATE/runs.json"
  add_run 100 "" 00:10
  add_pr 2
  add_run 200 2 00:20
  stop_at_tick 1
  run_wait
  assert_status 99
  assert_output_contains "Position 2 of 2 (weight -1)"
  # Without a pull request, the status is set on the commit of the run.
  [ "$(count_calls '^POST statuses/merge1 ')" -ge 1 ]
}

@test "the lock of a run without a pull request has no pull request number" {
  export PR_NUMBER="" BASE_REF="" HEAD_SHA="" HEAD_REPO=""
  echo '[]' >"$FAKE_STATE/runs.json"
  add_run 100 "" 00:10
  run_wait
  assert_status 0
  [ "$(lock_message 1)" = "wait-for-turn: run 100" ]
}

@test "keeps the last known labels when listing the pull requests fails" {
  export INPUT_LABEL_WEIGHTS="prio=5"
  holder_running
  add_pr 3 prio
  add_run 300 3 00:20
  at_tick 1 'fail_api 500 "^GET pulls$"; complete_run 200 failure'
  stop_at_tick 2
  run_wait
  assert_status 99
  assert_output_contains "Listing pull requests failed, using the last known labels."
  # Without the label, run 300 would be behind this run, which would take the turn.
  assert_output_contains "Position 2 of 2 (weight 0)"
  assert_locks 1
}

# --- Waiting for the holder's pull request to be merged ---

@test "keeps the turn held until the holder's pull request is merged" {
  holder_succeeded
  at_tick 2 'set_pr 2 ".state = \"closed\""'
  run_wait
  assert_status 0
  assert_output_contains "Run 200 completed, waiting for its pull request #2 to be merged."
  grep -qF "pending|Position 1 of 1 (weight 0). Waiting for #2 to be merged." "$FAKE_STATE/statuses.log"
  [ "$(count_calls '^sleep')" -eq 2 ]
  assert_holds 2
}

@test "doesn't wait for the merge when a new commit was pushed to the pull request" {
  holder_succeeded
  set_pr 2 '.head.sha = "head2b"'
  run_wait
  assert_status 0
  [ "$(count_calls '^sleep')" -eq 0 ]
  assert_holds 2
}

@test "doesn't wait for the merge when the pull request branch is behind" {
  holder_succeeded
  set_pr 2 '.mergeable_state = "behind"'
  run_wait
  assert_status 0
  [ "$(count_calls '^sleep')" -eq 0 ]
}

@test "doesn't wait for the merge when the holder failed" {
  add_pr 2 "" true
  add_run 200 2 00:05 completed failure
  hold_lock 1 200 2
  run_wait
  assert_status 0
  [ "$(count_calls '^sleep')" -eq 0 ]
}

@test "stops waiting for the merge after merge-wait-minutes" {
  export INPUT_MERGE_WAIT=1
  holder_succeeded
  run_wait
  assert_status 0
  assert_output_contains "waiting for its pull request #2 to be merged"
  [ "$(count_calls '^sleep')" -eq 2 ]
  assert_holds 2
}

@test "keeps the turn held when reading the holder's pull request fails" {
  holder_succeeded
  fail_api 500 '^GET pulls/2$'
  stop_at_tick 1
  run_wait
  assert_status 99
  assert_output_contains "Reading pull request #2 failed, retrying."
  assert_locks 1
}

@test "merge-wait-minutes 0 doesn't wait for the merge" {
  export INPUT_MERGE_WAIT=0
  holder_succeeded
  run_wait
  assert_status 0
  [ "$(count_calls '^sleep')" -eq 0 ]
}

# --- Letting pull requests with a higher weight go first ---

@test "lets a pull request with a higher weight go first until its commit was tested" {
  export INPUT_LABEL_WEIGHTS="prio=5"
  add_pr 3 prio true
  at_tick 1 'add_run 300 3 00:20 completed failure'
  run_wait
  assert_status 0
  assert_output_contains "Letting pull requests with a higher weight go first, they are about to be tested: #3."
  grep -qF "pending|Position 1 of 1 (weight 0). Letting #3 go first." "$FAKE_STATE/statuses.log"
  [ "$(count_calls '^sleep')" -eq 1 ]
  assert_holds 1
}

@test "a pull request that was let go first takes its place in the queue once its run starts" {
  export INPUT_LABEL_WEIGHTS="prio=5"
  add_pr 3 prio true
  at_tick 1 'add_run 300 3 00:20'
  stop_at_tick 2
  run_wait
  assert_status 99
  assert_output_contains "Position 2 of 2 (weight 0)"
  assert_locks
}

@test "stops letting a pull request that is behind go first after yield-to-pending-minutes" {
  export INPUT_LABEL_WEIGHTS="prio=5" INPUT_YIELD_MINUTES=1
  add_pr 3 prio true
  set_behind head3 2
  run_wait
  assert_status 0
  assert_output_contains "they are about to be tested: #3."
  [ "$(count_calls '^sleep')" -eq 2 ]
  # A commit that is behind stays behind, it is not compared again.
  [ "$(count_calls '^GET compare/main...head3$')" -eq 1 ]
  assert_holds 1
}

@test "doesn't let pull requests with the same weight go first" {
  add_pr 3 "" true
  run_wait
  assert_status 0
  [ "$(count_calls '^sleep')" -eq 0 ]
}

@test "doesn't let pull requests without auto-merge go first" {
  export INPUT_LABEL_WEIGHTS="prio=5"
  add_pr 3 prio false
  run_wait
  assert_status 0
  [ "$(count_calls '^sleep')" -eq 0 ]
}

@test "lets a pull request go first when its branch can't be compared" {
  export INPUT_LABEL_WEIGHTS="prio=5"
  add_pr 3 prio true
  fail_api 500 '^GET compare/'
  stop_at_tick 1
  run_wait
  assert_status 99
  assert_output_contains "they are about to be tested: #3."
  assert_locks
}

@test "yield-to-pending-minutes 0 doesn't let pull requests go first" {
  export INPUT_LABEL_WEIGHTS="prio=5" INPUT_YIELD_MINUTES=0
  add_pr 3 prio true
  run_wait
  assert_status 0
  [ "$(count_calls '^sleep')" -eq 0 ]
}

# --- require-up-to-date ---

@test "require-up-to-date takes the turn when the branch is up to date" {
  export INPUT_REQUIRE_UP_TO_DATE=true
  run_wait
  assert_status 0
  assert_output_contains "Branch is up to date with main."
  assert_holds 1
}

@test "require-up-to-date fails when the branch is behind" {
  export INPUT_REQUIRE_UP_TO_DATE=true
  set_behind head1 3
  run_wait
  assert_status 1
  assert_output_contains "::error::Branch is 3 commit(s) behind main. Update the branch to run the tests."
  assert_last_commit_status "failure|Branch is 3 commit(s) behind main."
  [ "$(count_calls '^PR ')" -eq 0 ]
  assert_locks
}

@test "require-up-to-date fails when the branch falls behind while waiting" {
  export INPUT_REQUIRE_UP_TO_DATE=true INPUT_QUEUED_POLL_INTERVAL=60
  holder_running
  at_tick 1 'set_behind head1 1'
  run_wait
  assert_status 1
  assert_output_contains "Branch is 1 commit(s) behind main."
  assert_locks 1
}

@test "update-token rebases a branch that is behind" {
  export INPUT_REQUIRE_UP_TO_DATE=true UPDATE_TOKEN=update
  set_behind head1 3
  run_wait
  assert_status 1
  assert_output_contains "::notice::Branch was 3 commit(s) behind main and was rebased."
  [ "$(count_calls '^PR update-branch 1 --rebase -R owner/repo token=update$')" -eq 1 ]
  assert_last_commit_status "failure|Branch was behind main and was rebased. The new commit starts a new run."
}

@test "update-token doesn't touch branches of forks" {
  export INPUT_REQUIRE_UP_TO_DATE=true UPDATE_TOKEN=update HEAD_REPO=someone/repo
  set_behind head1 3
  run_wait
  assert_status 1
  assert_output_contains "::notice::The branch is in another repository and can't be updated."
  assert_output_contains "::error::Branch is 3 commit(s) behind main."
  [ "$(count_calls '^PR ')" -eq 0 ]
}

@test "fails when rebasing the branch fails" {
  export INPUT_REQUIRE_UP_TO_DATE=true UPDATE_TOKEN=update
  set_behind head1 3
  fail_api 422 '^PR update-branch$'
  run_wait
  assert_status 1
  assert_output_contains "rebasing it failed"
}

@test "fails when the branch can't be compared right before taking the turn" {
  export INPUT_REQUIRE_UP_TO_DATE=true
  fail_api 500 '^GET compare/'
  run_wait
  assert_status 1
  assert_output_contains "Comparing with main failed, retrying later."
  assert_output_contains "::error::Comparing with main failed."
  assert_locks
}

@test "require-up-to-date is skipped for runs without a pull request" {
  export INPUT_REQUIRE_UP_TO_DATE=true PR_NUMBER="" BASE_REF="" HEAD_SHA="" HEAD_REPO=""
  run_wait
  assert_status 0
  assert_output_contains "::notice::require-up-to-date only applies to pull_request events"
  [ "$(count_calls '^GET compare/')" -eq 0 ]
}

# --- Timeout and inputs ---

@test "fails after timeout-minutes" {
  export INPUT_TIMEOUT_MINUTES=1
  holder_running
  run_wait
  assert_status 1
  assert_output_contains "::error::Timed out after 1 minutes waiting for the turn."
  assert_last_commit_status "failure|Timed out after 1 minutes waiting for the turn."
  [ "$(count_calls '^sleep')" -eq 2 ]
}

@test "rejects an invalid no-pull-request-weight" {
  export INPUT_NO_PR_WEIGHT=abc
  run_wait
  assert_status 1
  assert_output_contains "::error::Invalid no-pull-request-weight: abc. Expected an integer."
}

@test "rejects an invalid label-weights line" {
  export INPUT_LABEL_WEIGHTS=$'prio=5\nrenovate'
  run_wait
  [ "$status" -ne 0 ]
  assert_output_contains "Invalid label-weights line: renovate. Expected label=weight."
  assert_locks
}

# --- Commit status ---

@test "the commit status is set on the head commit of the pull request" {
  run_wait
  assert_status 0
  [ "$(count_calls '^POST statuses/')" -eq "$(count_calls '^POST statuses/head1 ')" ]
}

@test "the commit status is only set when it changes" {
  holder_running
  at_tick 3 'complete_run 200 failure'
  run_wait
  assert_status 0
  diff - "$FAKE_STATE/statuses.log" <<'EOF'
pending|Waiting for the turn.
pending|Position 1 of 1 (weight 0). Turn held by #2.
success|Took the turn after 1 min.
EOF
}

@test "commit status descriptions are cut to 140 characters" {
  export INPUT_LABEL_WEIGHTS="prio=5"
  for n in $(seq 10 49); do
    add_pr "$n" prio true
  done
  stop_at_tick 1
  run_wait
  assert_status 99
  letting=$(grep -F "Letting #10 #11 " "$FAKE_STATE/statuses.log")
  # "pending|" is 8 characters.
  [ "$((${#letting} - 8))" -eq 140 ]
}

@test "a failing commit status doesn't stop the waiting" {
  fail_api 403 '^POST statuses/'
  run_wait
  assert_status 0
  assert_output_contains "::warning::Setting commit status wait-for-turn failed"
  [ "$(count_calls '^POST statuses/')" -eq 1 ]
  assert_holds 1
}

@test "no commit status without status-context" {
  export INPUT_STATUS_CONTEXT=""
  run_wait
  assert_status 0
  [ "$(count_calls '^POST statuses/')" -eq 0 ]
}
