#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
validator="$script_dir/verify-release-ancestry.sh"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/meterbar-release-ancestry.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

# Scratch commits must not inherit signing, hooks, or templates from the runner.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

repository="$temporary_directory/repository"
git init --quiet --initial-branch=master "$repository"
git -C "$repository" config user.name "MeterBar CI"
git -C "$repository" config user.email "ci@meterbar.dev"

touch "$repository/history"
git -C "$repository" add history
git -C "$repository" commit --quiet -m "Initial commit"
ancestor_commit=$(git -C "$repository" rev-parse HEAD)

echo "master" >> "$repository/history"
git -C "$repository" commit --quiet -am "Master commit"
master_commit=$(git -C "$repository" rev-parse HEAD)
git -C "$repository" update-ref refs/remotes/origin/master "$master_commit"

git -C "$repository" checkout --quiet -b unmerged-descendant "$master_commit"
echo "unmerged descendant" >> "$repository/history"
git -C "$repository" commit --quiet -am "Unmerged descendant"
descendant_commit=$(git -C "$repository" rev-parse HEAD)

git -C "$repository" checkout --quiet -b side-branch "$ancestor_commit"
echo "side branch" >> "$repository/history"
git -C "$repository" commit --quiet -am "Side-branch commit"
side_branch_commit=$(git -C "$repository" rev-parse HEAD)

git -C "$repository" checkout --quiet master

(
  cd "$repository"
  "$validator" "$ancestor_commit"
)

(
  cd "$repository"
  "$validator" "$master_commit"
)

if (
  cd "$repository"
  "$validator" "$descendant_commit" >/dev/null 2>&1
); then
  echo "An unmerged descendant of origin/master was accepted." >&2
  exit 1
fi

if (
  cd "$repository"
  "$validator" "$side_branch_commit" >/dev/null 2>&1
); then
  echo "A side-branch release commit was accepted." >&2
  exit 1
fi

if (
  cd "$temporary_directory"
  "$validator" "$ancestor_commit" >/dev/null 2>&1
); then
  echo "Release ancestry passed outside a Git worktree." >&2
  exit 1
fi

if (
  cd "$repository"
  "$validator" HEAD >/dev/null 2>&1
); then
  echo "Malformed release commit input was accepted." >&2
  exit 1
fi

if (
  cd "$repository"
  "$validator" "$ancestor_commit" unexpected >/dev/null 2>&1
); then
  echo "Unexpected release ancestry arguments were accepted." >&2
  exit 1
fi

git -C "$repository" update-ref -d refs/remotes/origin/master
if (
  cd "$repository"
  "$validator" "$ancestor_commit" >/dev/null 2>&1
); then
  echo "Release ancestry passed without refs/remotes/origin/master." >&2
  exit 1
fi

echo "Release ancestry validation cases passed."
