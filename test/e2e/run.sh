#!/usr/bin/env bash
# Runs scenarios one after another and prints a PASS/FAIL line for each.
#
# Usage: run.sh [--ref <action ref>] [scenario number or name ...]
#
# Runs all scenarios but 00 by default. With --ref, setup.sh first points the
# test repository at that branch, tag or commit of the action, so
# `run.sh --ref main` tests the current main from scratch.
#
# The output of each scenario goes to results/<name>.log.
set -uo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$dir/results"
if [ "${1:-}" = --ref ]; then
  ref=${2:?--ref needs a branch, tag or commit}
  shift 2
  "$dir/setup.sh" "$ref" || exit 2
  printf -- '--- %s, action at %s\n' "$(date '+%Y-%m-%d %H:%M')" "$ref" | tee -a "$dir/results/run.txt"
fi
if [ $# -eq 0 ]; then
  for file in "$dir"/scenarios/*.sh; do
    name=$(basename "$file" .sh)
    [[ $name == 00-* ]] || set -- "$@" "$name"
  done
fi
failed=0
for scenario in "$@"; do
  files=("$dir/scenarios/$scenario"*.sh)
  file=${files[0]}
  if [ ! -f "$file" ]; then
    echo "no scenario $scenario" >&2
    exit 2
  fi
  name=$(basename "$file" .sh)
  start=$SECONDS
  if "$file" >"$dir/results/$name.log" 2>&1; then
    result=PASS
  else
    result=FAIL
    failed=$((failed + 1))
  fi
  printf '%s %s (%d min) results/%s.log\n' "$result" "$name" $(((SECONDS - start) / 60)) "$name" | tee -a "$dir/results/run.txt"
done
[ "$failed" -eq 0 ]
