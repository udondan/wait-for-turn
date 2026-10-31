#!/usr/bin/env bash
# Cancelled and timed out runs: a waiting run that is cancelled sets status
# error, a run that waits longer than timeout-minutes fails with status
# failure, and cancelling the holder mid-deploy frees the turn for the next.
# shellcheck source=test/e2e/lib.sh
source "$(dirname "$0")/../lib.sh"

scenario_start 12-cancel-timeout
configure DEPLOY_SECONDS=600
holder=$(plain_pr holder)
wait_until "#$holder took the turn" 300 is_holder "$holder"

configure DEPLOY_SECONDS=30
next=$(plain_pr next)
wait_until "#$next waits in line" 300 status_matches "$next" 'Position 1 of 1'
cancelled=$(plain_pr cancelled)
wait_until "#$cancelled waits in line" 300 status_matches "$cancelled" 'Position 2 of 2'
cancel_run "$(pr_run "$cancelled")"
wait_until "#$cancelled has status error" 120 status_matches "$cancelled" '^error'

configure TIMEOUT=1
timeout=$(plain_pr timeout)
wait_until "#$timeout timed out" 300 status_matches "$timeout" '^failure'
configure TIMEOUT=60

cancel_run "$(pr_run "$holder")"
wait_until "#$next took the turn" 120 is_holder "$next"

wait_settled 900
scenario_finish

expect_turn_order "$holder" "$next"
expect_gap "$next" 0 90
expect_final_status "$cancelled" '^error Cancelled while waiting for the turn\.$'
expect_final_status "$timeout" '^failure Timed out after 1 minutes waiting for the turn\.$'
expect_annotation "$timeout" '^failure Timed out after 1 minutes waiting for the turn\.$'
expect_final_status "$next" '^success Took the turn'
scenario_end
