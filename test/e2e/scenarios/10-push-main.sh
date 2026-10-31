#!/usr/bin/env bash
# Main is tested too, with no-pull-request-weight -100. Each merge starts a
# push run of main, which has to wait until the pull requests with auto-merge
# are done (it rebases them and lets them go first) and goes last. A newer push
# run cancels the older one through the concurrency group.
# shellcheck source=test/e2e/lib.sh
source "$(dirname "$0")/../lib.sh"

scenario_start 10-push-main
configure DEPLOY_SECONDS=60 TEST_MAIN=true USE_UPDATE_TOKEN=true UPDATE_PENDING=true
first=$(plain_pr first)
auto_merge "$first"
wait_until "#$first took the turn" 300 is_holder "$first"

configure DEPLOY_SECONDS=20
renovate=$(renovate_pr 1)
auto_merge "$renovate"
release=$(release_pr)
auto_merge "$release"

wait_until "all pull requests are merged" 2400 all_merged "$first" "$renovate" "$release"
wait_settled 1200
scenario_finish

expect_turn_pattern "$first $renovate $release( main)+"
expect_merged "$first" "$renovate" "$release"
expect_jq main-status "push runs of main set a status too" '[.runs[] | select(.event == "push" and .wait_conclusion == "success") | .statuses | last | .state == "success"] | any'
scenario_end
