#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fixture_dir="$script_dir/fixtures/swift-build-parity"
validator="$script_dir/verify-swift-build-parity.sh"
valid_debug="$fixture_dir/xcode-debug-valid.json"
valid_release="$fixture_dir/xcode-release-valid.json"
valid_package="$fixture_dir/Package-valid.swift"

expect_failure() {
  local name=$1
  local expected_message=$2
  shift 2
  local output

  if output=$("$validator" "$@" 2>&1); then
    echo "Swift build parity fixture '$name' was unexpectedly accepted." >&2
    exit 1
  fi

  if [[ "$output" != *"$expected_message"* ]]; then
    echo "Swift build parity fixture '$name' emitted an unexpected diagnostic:" >&2
    echo "$output" >&2
    exit 1
  fi
}

"$validator" "$valid_debug" "$valid_release" "$valid_package"

expect_failure \
  xcode-drift \
  "Xcode Debug SWIFT_VERSION mismatch" \
  "$fixture_dir/xcode-debug-version-drift.json" \
  "$valid_release" \
  "$valid_package"

expect_failure \
  package-drift \
  "SwiftPM target 'MeterBarTests' SWIFT_VERSION mismatch" \
  "$valid_debug" \
  "$valid_release" \
  "$fixture_dir/Package-version-drift.swift"

expect_failure \
  missing-setting \
  "Xcode Debug SWIFT_DEFAULT_ACTOR_ISOLATION missing" \
  "$fixture_dir/xcode-debug-missing-isolation.json" \
  "$valid_release" \
  "$valid_package"

expect_failure \
  malformed-json \
  "Xcode Debug build-settings JSON malformed" \
  "$fixture_dir/xcode-malformed.json" \
  "$valid_release" \
  "$valid_package"

echo "Swift build parity fixtures passed."
