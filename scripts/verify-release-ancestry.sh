#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <release-commit-sha>" >&2
  exit 64
fi

release_commit="$1"
master_ref="refs/remotes/origin/master"

# The workflow supplies github.sha, so accept only a full object ID. Besides
# producing a precise malformed-input error, this prevents revision syntax from
# changing what git resolves below.
if [[ ! "$release_commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Release commit must be a full 40-character lowercase Git SHA." >&2
  exit 64
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Release ancestry must be verified from inside a Git worktree." >&2
  exit 1
fi

if ! release_commit=$(git rev-parse --verify "${release_commit}^{commit}" 2>/dev/null); then
  echo "Release commit does not resolve to a commit: $1" >&2
  exit 1
fi

if ! master_commit=$(git rev-parse --verify "${master_ref}^{commit}" 2>/dev/null); then
  echo "Required master reference is missing or invalid: $master_ref" >&2
  exit 1
fi

if ! git merge-base --is-ancestor "$release_commit" "$master_commit"; then
  echo "Release commit $release_commit is not an ancestor of $master_ref ($master_commit)." >&2
  exit 1
fi

echo "Release commit $release_commit is an ancestor of $master_ref ($master_commit)."
