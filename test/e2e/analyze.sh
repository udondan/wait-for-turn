#!/usr/bin/env bash
# Runs the generic checks of analyze.jq on a scenario's results and prints
# them with a timeline of the turns.
#
# Usage: analyze.sh <results dir> [max idle seconds, default 180]
# Writes <results dir>/report.json, appends the checks to summary.txt. Exits 1
# when a check failed.
set -euo pipefail

dir=$1
max_gap=${2:-180}
here=$(cd "$(dirname "$0")" && pwd)

jq -n --slurpfile snaps "$dir/snapshots.jsonl" --slurpfile final "$dir/final.json" \
  --slurpfile config "$dir/config.json" --argjson max_gap "$max_gap" \
  -f "$here/analyze.jq" >"$dir/report.json"

echo "Turns:"
jq -r '.turns[] | "  \(.t)  lock \(.workflow)/\(.n)  \(if .pr then "#\(.pr)" else "main" end)  weight \(.weight)  run \(.run)"' "$dir/report.json"
echo "Runs:"
jq -r '.runs[] | "  run \(.run) \(if .pr then "#\(.pr)" else .event end) [\(.workflow)] wait \(.wait_conclusion)\n" + (.statuses | map("      \(.at) \(.state): \(.description)") | join("\n"))' "$dir/report.json"
echo "Checks:"
jq -r '.checks[] | "\(if .ok then "PASS" else "FAIL" end) \(.name): \(.detail)"' "$dir/report.json" | tee -a "$dir/summary.txt"
jq -e '.checks | all(.ok)' "$dir/report.json" >/dev/null
