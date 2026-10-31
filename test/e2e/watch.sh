#!/usr/bin/env bash
# Prints a line whenever the lock holder, a pull request's latest wait-for-turn
# status, its merge state or a failed check changes. For watching a scenario
# live: test/e2e/watch.sh [interval seconds, default 15]
set -uo pipefail
R=${E2E_REPO:-udondan/wait-for-turn-e2e}
interval=${1:-15}
declare -A last=()
emit() {
  local key=$1 value=$2
  if [ "${last[$key]:-}" != "$value" ]; then
    last[$key]=$value
    printf '%s %s: %s\n' "$(date +%T)" "$key" "$value"
  fi
}
while true; do
  sha=$(gh api "repos/$R/git/matching-refs/wait-for-turn/pipeline.yml/" --jq 'sort_by(.ref | split("/") | last | tonumber) | last.object.sha // empty' 2>/dev/null)
  if [ -n "$sha" ]; then
    emit lock "$(gh api "repos/$R/git/commits/$sha" --jq .message 2>/dev/null)"
  else
    emit lock none
  fi
  overlaps=$(gh api "repos/$R/git/matching-refs/e2e-resource/overlap" --jq '[.[].ref] | join(" ")' 2>/dev/null)
  [ -n "$overlaps" ] && emit OVERLAP "$overlaps"
  while read -r number head; do
    [ -n "$number" ] || continue
    status=$(gh api "repos/$R/commits/$head/statuses" --jq '[.[] | select(.context == "wait-for-turn")][0] // empty | "\(.state) \(.description)"' 2>/dev/null)
    pr=$(gh pr view "$number" -R "$R" --json state,mergeStateStatus,autoMergeRequest,statusCheckRollup --jq '"\(.state) \(.mergeStateStatus) auto-merge=\(.autoMergeRequest != null) failed=\([.statusCheckRollup[] | select((.conclusion // .state) == "FAILURE" or (.conclusion // .state) == "ERROR") | .name // .context] | join(","))"' 2>/dev/null)
    emit "#$number" "${head:0:7} [$status] $pr"
  done < <(gh pr list -R "$R" --state all --limit 15 --json number,headRefOid,updatedAt --jq '.[] | select(.updatedAt > (now - 3600 | todate)) | "\(.number) \(.headRefOid)"' 2>/dev/null)
  sleep "$interval"
done
