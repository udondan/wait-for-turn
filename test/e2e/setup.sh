#!/usr/bin/env bash
# Creates or updates the test repository (E2E_REPO, default
# udondan/wait-for-turn-e2e): pushes template/ with the pipeline using
# wait-for-turn at <action ref>, enables auto-merge, creates the labels and a
# ruleset that requires the checks "required" (pipeline.yml) and "extra-check"
# (extra.yml) and up-to-date branches, and sets
# the default variables. Safe to run again, for example to test another ref.
#
# Usage: setup.sh [action ref, default main]
#
# The secret UPDATE_TOKEN has to be set by hand, see README.md.
set -euo pipefail

# shellcheck source=test/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
action_ref=${1:-main}

if ! gh repo view "$E2E_REPO" --json name >/dev/null 2>&1; then
  log "creating $E2E_REPO"
  gh repo create "$E2E_REPO" --public --description "End-to-end tests of udondan/wait-for-turn. Throwaway, changed by scripts." >/dev/null
fi

gh api -X PATCH "$R" -F allow_auto_merge=true -F allow_squash_merge=true -F allow_merge_commit=false \
  -F allow_rebase_merge=false -F delete_branch_on_merge=true -F allow_update_branch=true \
  -F has_wiki=false -F has_projects=false --silent

# The ruleset blocks pushes to main, so it is disabled while the template is
# pushed.
ruleset_id=$(gh api "$R/rulesets" --jq '.[] | select(.name == "main") | .id')
ruleset() {
  jq -n --arg enforcement "$1" '{
    name: "main", target: "branch", enforcement: $enforcement,
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    rules: [{type: "required_status_checks", parameters: {
      strict_required_status_checks_policy: true,
      required_status_checks: [
        {context: "required", integration_id: 15368},
        {context: "extra-check", integration_id: 15368}]}}]}'
}
if [ -n "$ruleset_id" ]; then
  ruleset disabled | gh api -X PUT "$R/rulesets/$ruleset_id" --input - --silent
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if [ "$(gh api "$R" --jq .size)" = 0 ] && ! gh api "$R/git/ref/heads/main" --silent 2>/dev/null; then
  git -C "$work" init -q -b main
  git -C "$work" remote add origin "https://github.com/$E2E_REPO.git"
else
  git clone -q "https://github.com/$E2E_REPO.git" "$work"
  find "$work" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
fi
cp -R "$E2E_DIR/template/." "$work/"
sed -i.bak "s|__ACTION_REF__|$action_ref|g" "$work/.github/workflows/"*.yml
rm "$work/.github/workflows/"*.bak
# shellcheck disable=SC2016 # Markdown backticks
printf '# wait-for-turn e2e\n\nThrowaway repository for the end-to-end tests of [wait-for-turn](https://github.com/udondan/wait-for-turn), see test/e2e there. Changed by scripts, testing `%s`.\n' "$action_ref" >"$work/README.md"
git -C "$work" add -A
if ! git -C "$work" diff --cached --quiet; then
  # The test repository has no feature branches for its pipeline, allow a
  # commit to main past local hooks that block it.
  ALLOW_MAIN=true git -C "$work" -c user.name="$(gh api user --jq .login)" -c user.email="$(gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"')" commit -q -m "chore: set up pipeline with wait-for-turn@$action_ref"
  ALLOW_MAIN=true git -C "$work" push -q origin main
  log "pushed template with wait-for-turn@$action_ref"
fi

if [ -n "$ruleset_id" ]; then
  ruleset active | gh api -X PUT "$R/rulesets/$ruleset_id" --input - --silent
else
  ruleset active | gh api -X POST "$R/rulesets" --input - --silent
fi

gh label create renovate -R "$E2E_REPO" --color 1f6feb --force >/dev/null
gh label create "autorelease: pending" -R "$E2E_REPO" --color ededed --force >/dev/null
gh label create urgent -R "$E2E_REPO" --color d73a4a --force >/dev/null

configure "${DEFAULT_VARS[@]}" "LABEL_WEIGHTS=$DEFAULT_LABEL_WEIGHTS"

if ! gh secret list -R "$E2E_REPO" --json name --jq '.[].name' | grep -qx UPDATE_TOKEN; then
  log "secret UPDATE_TOKEN is missing. Create a fine-grained token for $E2E_REPO only with"
  log "Contents and Pull requests read and write, then run: gh secret set UPDATE_TOKEN -R $E2E_REPO"
fi
log "$E2E_REPO is ready: https://github.com/$E2E_REPO"
