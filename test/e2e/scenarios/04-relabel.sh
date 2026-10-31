#!/usr/bin/env bash
# Labelling a waiting pull request moves its run in the queue: the last of
# four waiting Renovate pull requests is labelled urgent and goes next.
# shellcheck source=test/e2e/lib.sh
source "$(dirname "$0")/../lib.sh"

scenario_start 04-relabel
configure DEPLOY_SECONDS=150
holder=$(plain_pr holder)
wait_until "#$holder took the turn" 300 is_holder "$holder"

configure DEPLOY_SECONDS=20
r1=$(renovate_pr 1)
sleep 3
r2=$(renovate_pr 2)
sleep 3
r3=$(renovate_pr 3)
sleep 3
r4=$(renovate_pr 4)
wait_until "#$r4 is last in line" 300 status_matches "$r4" 'Position 4 of 4'
add_label "$r4" urgent
wait_until "#$r4 moved to the front" 120 status_matches "$r4" 'Position 1 of 4 \(weight 5\)'

wait_settled 1800
scenario_finish

expect_turn_order "$holder" "$r4" "$r1" "$r2" "$r3"
expect_status "$r4" '^pending Position 4 of 4 \(weight -5\)'
expect_status "$r4" '^pending Position 1 of 4 \(weight 5\)'
scenario_end
