#!/usr/bin/env bash
# Six Renovate pull requests with auto-merge, opened at the same time, with
# require-up-to-date and update-token. Each merge makes the others behind: their
# waiting runs rebase them and fail, the new commits queue again. The holder
# keeps the turn until its pull request is merged. In the end all are merged
# one after another, without anyone touching them.
# shellcheck disable=SC2016 # jq variables in single quotes
# shellcheck source=test/e2e/lib.sh
source "$(dirname "$0")/../lib.sh"

scenario_start 06-renovate-storm
configure DEPLOY_SECONDS=30 USE_UPDATE_TOKEN=true

open_auto_merge() {
  local pr
  pr=$(renovate_pr "$1")
  auto_merge "$pr" >&2
  echo "$pr"
}
# Waits for these jobs only, the observer runs in the background too.
jobs=()
for i in 1 2 3 4 5 6; do
  open_auto_merge "$i" >"$RESULTS/pr-$i" &
  jobs+=($!)
done
wait "${jobs[@]}"
# shellcheck disable=SC2046 # one number per file
set -- $(cat "$RESULTS"/pr-*)

wait_until "all pull requests are merged" 5400 all_merged "$@"
wait_settled 600
MAX_GAP=300 scenario_finish

expect_merged "$@"
expect_jq turns "every pull request took the turn once with its last commit" '[.turns[] | select(.workflow == "pipeline.yml")] | length == 6'
expect_jq rebased "waiting runs rebased behind branches and failed" '[.runs[].annotations[] | .message | test("was rebased\\. The new commit starts a new run\\.$")] | any'
expect_jq rebased-status "the status of a rebased commit says so" '[.runs[].statuses | last // empty | .state == "failure" and (.description | test("^Branch was behind main and was rebased\\."))] | any'
expect_jq merge-wait "a run waited for the holder to be merged" '[.runs[].statuses[].description | test("Waiting for #[0-9]+ to be merged\\.$")] | any'
scenario_end
