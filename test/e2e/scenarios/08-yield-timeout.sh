#!/usr/bin/env bash
# Like 07, but the pending pull request is never tested. The release pull
# request waits yield-to-pending-minutes (2) and then takes the turn.
# shellcheck source=test/e2e/lib.sh
source "$(dirname "$0")/../lib.sh"

scenario_start 08-yield-timeout
configure DEPLOY_SECONDS=20 YIELD=2

renovate=$(SKIP_CI=true renovate_pr 1)
auto_merge "$renovate"
release=$(release_pr)

wait_settled 900
scenario_finish

expect_turn_order "$release"
expect_status "$release" "Letting #$renovate go first\.$"
expect_final_status "$release" '^success Took the turn after 2 min\.$'
scenario_end
