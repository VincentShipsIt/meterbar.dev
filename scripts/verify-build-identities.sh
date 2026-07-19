#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd "$script_dir/.." && pwd)
project="$repository_root/MeterBar.xcodeproj"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/meterbar-build-identities.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

read_setting() {
  local settings_file="$1"
  local key="$2"

  plutil -extract "0.buildSettings.$key" raw -o - "$settings_file"
}

assert_setting() {
  local settings_file="$1"
  local key="$2"
  local expected="$3"
  local actual

  actual=$(read_setting "$settings_file" "$key")
  if [ "$actual" != "$expected" ]; then
    echo "$key mismatch: expected '$expected', got '$actual'." >&2
    exit 1
  fi
}

verify_target() {
  local target="$1"
  local configuration="$2"
  local expected_bundle_identifier="$3"
  local expected_product_name="$4"
  local expected_full_product_name="$5"
  local expected_display_name="${6:-}"
  local settings_file="$temporary_directory/${target}-${configuration}.json"

  xcodebuild \
    -project "$project" \
    -scheme "$target" \
    -configuration "$configuration" \
    -destination 'generic/platform=macOS' \
    -showBuildSettings \
    -json > "$settings_file"

  assert_setting "$settings_file" PRODUCT_BUNDLE_IDENTIFIER "$expected_bundle_identifier"
  assert_setting "$settings_file" PRODUCT_NAME "$expected_product_name"
  assert_setting "$settings_file" FULL_PRODUCT_NAME "$expected_full_product_name"
  if [ -n "$expected_display_name" ]; then
    assert_setting "$settings_file" INFOPLIST_KEY_CFBundleDisplayName "$expected_display_name"
  fi
}

verify_target MeterBar Debug dev.meterbar.app.debug "MeterBar Dev" "MeterBar Dev.app"
verify_target MeterBarWidgetExtension Debug \
  dev.meterbar.app.debug.Widget MeterBarWidgetExtension MeterBarWidgetExtension.appex
verify_target MeterBar Release dev.meterbar.app MeterBar MeterBar.app
verify_target MeterBarWidgetExtension Release \
  dev.meterbar.app.Widget MeterBarWidgetExtension MeterBarWidgetExtension.appex

"$script_dir/verify-swift-build-parity.sh" \
  "$temporary_directory/MeterBar-Debug.json" \
  "$temporary_directory/MeterBar-Release.json" \
  "$repository_root/Package.swift"

echo "Debug and Release app/widget identities and Swift build parity verified."
