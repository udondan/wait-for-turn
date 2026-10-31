#!/usr/bin/env bash
# Records what can't be read afterwards, every OBSERVE_INTERVAL seconds until
# killed: the lock refs (deleted when the next run takes the turn), the labels
# and auto-merge of the pull requests (they change) and the pull request of
# each run (the API drops it once the pull request is closed).
#
# Usage: observe.sh <results dir>. Appends one JSON object per line to
# <results dir>/snapshots.jsonl.
set -uo pipefail

dir=$1
repo="repos/${E2E_REPO:-udondan/wait-for-turn-e2e}"
interval=${OBSERVE_INTERVAL:-10}
out="$dir/snapshots.jsonl"
mkdir -p "$dir/lock-commits"

# Lock commits never change, cache them by sha.
lock_commit() {
  local file="$dir/lock-commits/$1.json"
  if [ ! -s "$file" ]; then
    gh api "$repo/git/commits/$1" --jq '{message, date: .committer.date}' >"$file.tmp" && mv "$file.tmp" "$file"
  fi
  cat "$file" 2>/dev/null || echo '{}'
}

while true; do
  t=$(date -u +%FT%TZ)
  if refs=$(gh api "$repo/git/matching-refs/wait-for-turn/" --jq '.[] | "\(.ref) \(.object.sha)"') &&
    prs=$(gh api "$repo/pulls?state=all&sort=updated&direction=desc&per_page=50" --jq '[.[] | {number, state, merged_at, auto_merge: (.auto_merge != null), labels: [.labels[].name], head_sha: .head.sha, head_ref: .head.ref}]') &&
    runs=$(gh api "$repo/actions/runs?per_page=100" --jq '[.workflow_runs[] | {id, run_attempt, status, conclusion, path, event, head_sha, head_branch, pr: (.pull_requests[0].number // null), run_started_at}]'); then
    locks='[]'
    while read -r ref sha; do
      [ -n "$ref" ] || continue
      locks=$(jq --arg ref "$ref" --arg sha "$sha" --argjson c "$(lock_commit "$sha")" '. + [{
        workflow: ($ref | split("/")[2]), n: ($ref | split("/")[3] | tonumber), sha: $sha,
        run: ($c.message // "" | capture("run (?<id>[0-9]+)").id // null | tonumber? // null),
        pr: ($c.message // "" | capture("pull request (?<pr>[0-9]+)").pr // null | tonumber? // null),
        created: $c.date}]' <<<"$locks")
    done <<<"$refs"
    jq -c -n --arg t "$t" --argjson locks "$locks" --argjson prs "$prs" --argjson runs "$runs" \
      '{t: $t, locks: $locks, prs: $prs, runs: $runs}' >>"$out"
  else
    echo "observe: request failed at $t" >&2
  fi
  sleep "$interval"
done
