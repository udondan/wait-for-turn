#!/usr/bin/env bash
# A new commit is pushed to a waiting pull request. The concurrency group of
# the reusable workflow cancels the waiting run of the old commit, whose
# status turns to error. Or the old run sees the new one first and fails as
# outdated, a race that goes either way. The run of the new commit queues by
# its own start time, behind the pull request that was opened in between.
# shellcheck disable=SC2016 # jq variables in single quotes
# shellcheck source=test/e2e/lib.sh
source "$(dirname "$0")/../lib.sh"

scenario_start 05-new-commit
configure DEPLOY_SECONDS=150
holder=$(plain_pr holder)
wait_until "#$holder took the turn" 300 is_holder "$holder"

configure DEPLOY_SECONDS=20
a=$(plain_pr a)
wait_until "#$a waits in line" 300 status_matches "$a" 'Position 1 of 1'
old_sha=$(head_sha "$a")
b=$(plain_pr b)
wait_until "#$b waits in line" 300 status_matches "$b" 'Position 2 of 2'
push_commit "$a"

wait_settled 1800
scenario_finish

expect_turn_order "$holder" "$b" "$a"
expect_jq old-run-cancelled "the run of the old commit of #$a was cancelled while waiting" --arg sha "$old_sha" \
  '[.runs[] | select(.head_sha == $sha) | .wait_conclusion == "cancelled"] | any'
expect_jq old-status "the old commit of #$a ended cancelled or outdated" --arg sha "$old_sha" \
  '[.runs[] | select(.head_sha == $sha) | .statuses | last | "\(.state) \(.description)" | test("^(error Cancelled while waiting for the turn|failure Outdated, a newer commit of #[0-9]+ is tested)\\.$")] | any'
expect_final_status "$a" '^success Took the turn'
scenario_end
