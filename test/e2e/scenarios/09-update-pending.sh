#!/usr/bin/env bash
# Two Renovate pull requests with auto-merge were tested and failed as behind
# after another pull request was merged, and nothing updates them. Without
# update-pending-branches a release pull request would go first. With it, the
# release run rebases them, lets their new commits go first and goes last.
# shellcheck source=test/e2e/lib.sh
source "$(dirname "$0")/../lib.sh"

scenario_start 09-update-pending
configure DEPLOY_SECONDS=60
first=$(plain_pr first)
auto_merge "$first"
wait_until "#$first took the turn" 300 is_holder "$first"

configure DEPLOY_SECONDS=20
a=$(renovate_pr 1)
auto_merge "$a"
b=$(renovate_pr 2)
auto_merge "$b"
wait_until "#$first is merged" 900 is_merged "$first"
wait_until "#$a failed as behind" 300 status_matches "$a" '^failure Branch is 1 commit\(s\) behind main\.$'
wait_until "#$b failed as behind" 300 status_matches "$b" '^failure Branch is 1 commit\(s\) behind main\.$'

configure USE_UPDATE_TOKEN=true UPDATE_PENDING=true
release=$(release_pr)

wait_until "#$a and #$b are merged" 2400 all_merged "$a" "$b"
wait_settled 1200
scenario_finish

expect_turn_pattern "$first ($a $b|$b $a) $release"
expect_status "$release" "Letting #($a|$b)(, #($a|$b))? go first\.$"
expect_merged "$first" "$a" "$b"
expect_final_status "$release" '^success Took the turn'
scenario_end
