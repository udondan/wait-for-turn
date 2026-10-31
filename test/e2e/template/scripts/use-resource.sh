#!/usr/bin/env bash
# Stands in for a job that uses a shared resource, like a test stack.
#
# Usage: use-resource.sh <resource> <seconds>
#
# Takes the resource by creating ref refs/e2e-resource/<resource>, holds it for
# <seconds>, then deletes the ref. Creating a ref that exists fails with HTTP
# 422: another run uses the resource at the same time, so wait-for-turn let two
# runs in. That is recorded as ref refs/e2e-resource/overlap-<run id>, which the
# e2e analyzer looks for, and fails the job.
#
# Fails on purpose when the checked out commit has a file named fail-deploy.
set -euo pipefail

resource=$1
seconds=$2
repo="repos/$GITHUB_REPOSITORY"
ref="e2e-resource/$resource"

tree=$(gh api "$repo/git/commits/$HEAD_SHA" --jq .tree.sha)
commit=$(gh api "$repo/git/commits" -f message="e2e-resource: run $GITHUB_RUN_ID, pull request ${PR_NUMBER:-none}" -f tree="$tree" --jq .sha)

if ! out=$(gh api "$repo/git/refs" -f ref="refs/$ref" -f sha="$commit" --silent 2>&1); then
  if [[ "$out" == *"HTTP 422"* ]]; then
    other=$(gh api "$repo/git/ref/$ref" --jq .object.sha)
    message=$(gh api "$repo/git/commits/$other" --jq .message || true)
    gh api "$repo/git/refs" -f ref="refs/e2e-resource/overlap-$GITHUB_RUN_ID" -f sha="$commit" --silent || true
    echo "::error::OVERLAP: resource $resource is already used by: $message"
    exit 1
  fi
  echo "::error::Taking resource $resource failed: $out"
  exit 1
fi

release() {
  # Delete the ref only while it is still ours.
  local current
  current=$(gh api "$repo/git/ref/$ref" --jq .object.sha 2>/dev/null || true)
  if [ "$current" = "$commit" ]; then
    gh api -X DELETE "$repo/git/refs/$ref" --silent || true
  fi
}
trap release EXIT
trap 'exit 130' INT TERM

echo "Using resource $resource for $seconds seconds."
# In the background, so the INT/TERM trap runs right away on cancel.
sleep "$seconds" &
wait "$!"

if [ -f fail-deploy ]; then
  echo "::error::Failing on purpose: fail-deploy exists."
  exit 1
fi
echo "Done."
