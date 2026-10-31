#!/usr/bin/env bash
# Holders with auto-merge that will never be merged release the turn right
# away: one whose deploy fails, and one whose deploy succeeds but whose other
# required check (extra-check) fails. The next run must not wait
# merge-wait-minutes (10) for a pull request that can't be merged.
# shellcheck source=test/e2e/lib.sh
source "$(dirname "$0")/../lib.sh"

scenario_start 11-failures
configure DEPLOY_SECONDS=30 MERGE_WAIT=10
failing=$(EXTRA_FILE=fail-deploy plain_pr failing-deploy)
auto_merge "$failing"
wait_until "#$failing took the turn" 300 is_holder "$failing"

unmergeable=$(EXTRA_FILE=fail-extra plain_pr failing-extra)
auto_merge "$unmergeable"
sleep 5
next=$(plain_pr next)

wait_settled 1500
scenario_finish

expect_turn_order "$failing" "$unmergeable" "$next"
expect_gap "$unmergeable" 0 120
expect_gap "$next" 0 120
expect_final_status "$next" '^success Took the turn'
scenario_end
