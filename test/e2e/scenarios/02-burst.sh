#!/usr/bin/env bash
# Six pull requests opened at the same time. Their runs all see the turn free
# at once and race for the lock ref: only one may get it at a time, and they
# go in the order their runs started.
# shellcheck disable=SC2016 # jq variables in single quotes
# shellcheck source=test/e2e/lib.sh
source "$(dirname "$0")/../lib.sh"

scenario_start 02-burst
configure DEPLOY_SECONDS=30

# Waits for these jobs only, the observer runs in the background too.
jobs=()
for i in 1 2 3 4 5 6; do
  plain_pr "burst-$i" >"$RESULTS/pr-$i" &
  jobs+=($!)
done
wait "${jobs[@]}"
prs=$(cat "$RESULTS"/pr-*)

wait_settled 1800
scenario_finish

expect_jq turns "all 6 pull requests took the turn once" '[.turns[] | select(.workflow == "pipeline.yml")] | length == 6'
for pr in $prs; do
  expect_final_status "$pr" '^success Took the turn'
done
expect_jq positions "statuses showed the place in the queue" '[.runs[].statuses[].description | test("^Position [2-6] of [2-6] \\(weight 0\\)\\. Turn held by #[0-9]+\\.$")] | any'
scenario_end
