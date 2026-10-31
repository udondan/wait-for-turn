#!/usr/bin/env bash
# A Renovate pull request with auto-merge has a head commit without a run yet
# (made with [skip ci], like a branch that is about to be tested). The run of a
# release pull request, which has a lower weight, finds the turn free but lets
# it go first. Once its commit is tested, it takes the turn, and the release
# pull request is rebased after it was merged and goes second.
# shellcheck source=test/e2e/lib.sh
source "$(dirname "$0")/../lib.sh"

scenario_start 07-yield
configure DEPLOY_SECONDS=30 YIELD=5 USE_UPDATE_TOKEN=true

renovate=$(SKIP_CI=true renovate_pr 1)
auto_merge "$renovate"
release=$(release_pr)
wait_until "#$release lets #$renovate go first" 300 status_matches "$release" "Letting #$renovate go first\."
sleep 30
push_commit "$renovate"

wait_until "#$renovate is merged" 1200 is_merged "$renovate"
wait_settled 1200
scenario_finish

expect_turn_order "$renovate" "$release"
expect_status "$release" "^pending Position 1 of 1 \(weight -10\)\. Letting #$renovate go first\.$"
expect_merged "$renovate"
expect_annotation "$release" 'was rebased\. The new commit starts a new run\.$'
expect_final_status "$release" '^success Took the turn'
scenario_end
