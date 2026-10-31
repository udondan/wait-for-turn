#!/usr/bin/env bash
# Re-runs: re-running the run that holds the turn keeps it without a new lock.
# Once another run took the turn, a re-run queues by its new start time.
# shellcheck disable=SC2016 # jq variables in single quotes
# shellcheck source=test/e2e/lib.sh
source "$(dirname "$0")/../lib.sh"

scenario_start 13-reruns
configure DEPLOY_SECONDS=20
rerun_pr=$(EXTRA_FILE=fail-deploy plain_pr rerun)
wait_settled 600
run=$(pr_run "$rerun_pr")
rerun "$run"
wait_settled 600

configure DEPLOY_SECONDS=90
b=$(plain_pr b)
wait_until "#$b took the turn" 300 is_holder "$b"
c=$(plain_pr c)
wait_until "#$c waits in line" 300 status_matches "$c" 'Position 1 of 1'
rerun "$run"

wait_settled 1200
scenario_finish

expect_turn_order "$rerun_pr" "$b" "$c" "$rerun_pr"
expect_jq attempts "run $run ran 3 times" --argjson run "$run" '[.runs[] | select(.run == $run) | .attempts | length] == [3]'
expect_jq locks "the first re-run took no new lock" --argjson run "$run" '[.turns[] | select(.run == $run)] | length == 2'
scenario_end
