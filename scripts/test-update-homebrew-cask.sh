#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fixture_dir="$script_dir/fixtures/homebrew"
updater="$script_dir/update-homebrew-cask.sh"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/meterbar-homebrew-cask.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

test_sha256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
updated_cask="$temporary_directory/meterbar.rb"

cp "$fixture_dir/meterbar-stale.rb" "$updated_cask"
"$updater" \
  "$updated_cask" \
  "9.8.7" \
  "$test_sha256" \
  "VincentShipsIt/meterbar.dev"
diff -u "$fixture_dir/meterbar-expected.rb" "$updated_cask"

malformed_cask="$temporary_directory/meterbar-malformed.rb"
malformed_before="$temporary_directory/meterbar-malformed-before.rb"
cp "$fixture_dir/meterbar-malformed.rb" "$malformed_cask"
cp "$malformed_cask" "$malformed_before"

if "$updater" \
  "$malformed_cask" \
  "9.8.7" \
  "$test_sha256" \
  "VincentShipsIt/meterbar.dev" >/dev/null 2>&1; then
  echo "Unexpected Homebrew cask layout was accepted." >&2
  exit 1
fi

if ! cmp -s "$malformed_before" "$malformed_cask"; then
  echo "Rejected Homebrew cask was modified before validation completed." >&2
  exit 1
fi

echo "Homebrew cask update fixtures passed."
