#!/usr/bin/env bash
# One pull request: it takes the free turn and its commit status goes from
# pending to success.
# shellcheck source=test/e2e/lib.sh
source "$(dirname "$0")/../lib.sh"

scenario_start 01-smoke
configure DEPLOY_SECONDS=20

pr=$(plain_pr smoke)
wait_until "#$pr took the turn" 300 is_holder "$pr"
wait_settled 600
scenario_finish

expect_turn_order "$pr"
expect_status "$pr" '^pending Waiting for the turn\.$'
expect_final_status "$pr" '^success Took the turn\.$'
scenario_end
