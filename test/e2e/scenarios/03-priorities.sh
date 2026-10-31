#!/usr/bin/env bash
# While one pull request holds the turn, pull requests with different labels
# queue up: urgent (10), unlabelled (0), renovate (-5), autorelease: pending
# (-10). They take the turn by weight, then by start time, not in the order
# they were opened.
# shellcheck source=test/e2e/lib.sh
source "$(dirname "$0")/../lib.sh"

scenario_start 03-priorities
configure DEPLOY_SECONDS=150
holder=$(plain_pr holder)
wait_until "#$holder took the turn" 300 is_holder "$holder"

# The waiting runs use the resource shortly.
configure DEPLOY_SECONDS=20
renovate1=$(renovate_pr 1)
sleep 3
release=$(release_pr)
sleep 3
renovate2=$(renovate_pr 2)
sleep 3
human=$(plain_pr human)
sleep 3
renovate3=$(renovate_pr 3)
sleep 3
urgent=$(plain_pr urgent urgent)

wait_until "#$urgent waits in line" 300 status_matches "$urgent" 'Position 1 of 6 \(weight 10\)'
wait_settled 1800
scenario_finish

expect_turn_order "$holder" "$urgent" "$human" "$renovate1" "$renovate2" "$renovate3" "$release"
expect_status "$release" '^pending Position 6 of 6 \(weight -10\)\. Turn held by #[0-9]+\.$'
expect_status "$renovate1" '^pending Position [2-5] of [0-9] \(weight -5\)'
scenario_end
