#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd "$script_dir/.." && pwd)
retired_repository_suffix="app"
retired_repository="VincentShipsIt/meterbar.$retired_repository_suffix"
# This input fixture is the sole intentional retired URL: it proves that the
# cask updater migrates the old repository without letting source references regress.
allowed_migration_fixture="scripts/fixtures/homebrew/meterbar-stale.rb"
scan_paths=(
  .github
  MeterBar
  MeterBarWidget
  MeterBarCLI
  Packages
  scripts
  README.md
  .agents/docs/SETUP.md
  Package.swift
)
violations=()

while IFS= read -r file; do
  if [ "$file" = "$allowed_migration_fixture" ]; then
    continue
  fi

  while IFS= read -r match; do
    violations+=("$file:$match")
  done < <(grep -nF "$retired_repository" "$repository_root/$file" || true)
done < <(git -C "$repository_root" ls-files -- "${scan_paths[@]}")

if [ "${#violations[@]}" -gt 0 ]; then
  echo "Retired repository URL found outside the documented migration fixture:" >&2
  printf '  %s\n' "${violations[@]}" >&2
  exit 1
fi

echo "Canonical repository URL hygiene verified."
