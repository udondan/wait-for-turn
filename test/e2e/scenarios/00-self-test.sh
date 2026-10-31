#!/usr/bin/env bash
# Checks the harness itself: the resource is taken by hand before a run gets
# to it, so its deploy has to detect the overlap and the analyzer has to report
# mutual exclusion as failed. If this passes, a PASS of mutual-exclusion in the
# other scenarios means something.
# shellcheck disable=SC2016 # jq variables in single quotes
# shellcheck source=test/e2e/lib.sh
source "$(dirname "$0")/../lib.sh"

scenario_start 00-self-test
configure DEPLOY_SECONDS=20

# Someone else uses the resource.
tree=$(gh api "$R/git/commits/$(main_sha)" --jq .tree.sha)
commit=$(gh api "$R/git/commits" -f message="e2e-resource: taken by hand" -f tree="$tree" --jq .sha)
gh api "$R/git/refs" -f ref=refs/e2e-resource/pipeline -f sha="$commit" --silent
log "took the resource by hand"

pr=$(plain_pr self-test)
wait_settled 900
gh api -X DELETE "$R/git/refs/e2e-resource/pipeline" --silent || true
scenario_finish

# The analyzer has to have caught it.
FAILURES=0
expect_jq overlap-detected "mutual-exclusion reported the overlap" '[.checks[] | select(.name == "mutual-exclusion") | .ok == false] | any'
expect_jq deploy-failed "the deploy of #$pr failed" --arg pr "$pr" '[.runs[] | select((.pr | tostring) == $pr) | .attempts[].deploy.conclusion == "failure"] | any'
expect_final_status "$pr" '^success Took the turn'
scenario_end
