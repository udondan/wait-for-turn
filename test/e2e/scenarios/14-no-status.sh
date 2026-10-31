#!/usr/bin/env bash
# The workflow nostatus.yml uses the action directly, with status-context set
# but without statuses: write. The action warns once, then queues without the
# status. Its queue is separate from the one of pipeline.yml.
# shellcheck disable=SC2016 # jq variables in single quotes
# shellcheck source=test/e2e/lib.sh
source "$(dirname "$0")/../lib.sh"

scenario_start 14-no-status
configure DEPLOY_SECONDS=30 NOSTATUS=true
a=$(plain_pr a)
sleep 3
b=$(plain_pr b)

wait_settled 900
scenario_finish

expect_jq nostatus-turns "both pull requests took the turn of nostatus.yml" --arg a "$a" --arg b "$b" '[.turns[] | select(.workflow == "nostatus.yml") | .pr | tostring] == [$a, $b]'
expect_jq no-statuses "no status wait-for-turn-nostatus was set" '[.runs[].statuses[] | select(.context == "wait-for-turn-nostatus")] | length == 0'
expect_annotation "$a" '^warning Setting commit status wait-for-turn-nostatus failed'
expect_turn_order "$a" "$b"
scenario_end
