#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 APP_PATH EXPECTED_VERSION" >&2
  echo "Signs ad-hoc by default; set SIGNING_IDENTITY (and optionally" >&2
  echo "SIGNING_KEYCHAIN) to sign with a Developer ID identity instead." >&2
  exit 64
fi

# Developer ID mode is opt-in via environment so CI PR builds keep the
# credential-free ad-hoc path while tag releases sign for real.
signing_identity="${SIGNING_IDENTITY:-}"
signing_keychain="${SIGNING_KEYCHAIN:-}"
if [ -n "$signing_keychain" ] && [ -z "$signing_identity" ]; then
  echo "SIGNING_KEYCHAIN requires SIGNING_IDENTITY." >&2
  exit 64
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd "$script_dir/.." && pwd)
app_path="$1"
expected_version="$2"
widget_path="$app_path/Contents/PlugIns/MeterBarWidgetExtension.appex"
app_binary="$app_path/Contents/MacOS/MeterBar"
widget_binary="$widget_path/Contents/MacOS/MeterBarWidgetExtension"
cli_binary="$app_path/Contents/Helpers/meterbar"
session_wake_agent_plist="$app_path/Contents/Library/LaunchAgents/dev.meterbar.app.session-wake.plist"
app_entitlements="$repository_root/MeterBar/MeterBar.entitlements"
widget_entitlements="$repository_root/MeterBarWidget/MeterBarWidget.entitlements"

if [[ ! "$expected_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "Expected version must match canonical MAJOR.MINOR.PATCH syntax." >&2
  exit 64
fi

for directory in "$app_path" "$widget_path"; do
  if [ ! -d "$directory" ]; then
    echo "Required bundle not found: $directory" >&2
    exit 1
  fi
done

for file in \
  "$app_binary" \
  "$widget_binary" \
  "$cli_binary" \
  "$session_wake_agent_plist" \
  "$app_entitlements" \
  "$widget_entitlements"; do
  if [ ! -f "$file" ]; then
    echo "Required release input not found: $file" >&2
    exit 1
  fi
done

plutil -lint "$session_wake_agent_plist"
agent_program=$(/usr/libexec/PlistBuddy -c "Print :BundleProgram" "$session_wake_agent_plist")
agent_command=$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:1" "$session_wake_agent_plist")
agent_run_at_load=$(/usr/libexec/PlistBuddy -c "Print :RunAtLoad" "$session_wake_agent_plist")
agent_restart_on_failure=$(/usr/libexec/PlistBuddy -c "Print :KeepAlive:SuccessfulExit" "$session_wake_agent_plist")
if [ "$agent_program" != "Contents/Helpers/meterbar" ] \
  || [ "$agent_command" != "wake-agent" ] \
  || [ "$agent_run_at_load" != "true" ] \
  || [ "$agent_restart_on_failure" != "false" ]; then
  echo "Session Wake launch-agent plist has an invalid command or lifecycle policy." >&2
  exit 1
fi

verify_universal_binary() {
  local binary="$1"
  local label="$2"

  if ! lipo "$binary" -verify_arch arm64 x86_64; then
    echo "$label is not universal arm64+x86_64: $(file "$binary")" >&2
    exit 1
  fi
  echo "$label architectures: $(lipo -archs "$binary")"
}

verify_universal_binary "$app_binary" "App"
verify_universal_binary "$widget_binary" "Widget"
verify_universal_binary "$cli_binary" "CLI"

app_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app_path/Contents/Info.plist")
app_build_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app_path/Contents/Info.plist")
cli_version=$("$cli_binary" --version)

echo "Tag version: $expected_version"
echo "App version: $app_version"
echo "App build version: $app_build_version"
echo "CLI version: $cli_version"

if [ "$app_version" != "$expected_version" ]; then
  echo "App version $app_version does not match release version $expected_version." >&2
  exit 1
fi
if [ "$app_build_version" != "$expected_version" ]; then
  echo "App build version $app_build_version does not match release version $expected_version." >&2
  exit 1
fi
if [ "$cli_version" != "$expected_version" ]; then
  echo "CLI version $cli_version does not match release version $expected_version." >&2
  exit 1
fi

sign_code() {
  local target="$1"
  shift
  if [ -n "$signing_identity" ]; then
    # Developer ID: a secure timestamp is required for notarization, and the
    # explicit keychain pins the identity to the CI temp keychain so codesign
    # cannot resolve a same-named certificate from another keychain.
    local keychain_args=()
    if [ -n "$signing_keychain" ]; then
      keychain_args=(--keychain "$signing_keychain")
    fi
    codesign \
      --force \
      --sign "$signing_identity" \
      "${keychain_args[@]}" \
      --timestamp \
      --options runtime \
      --generate-entitlement-der \
      "$@" \
      "$target"
  else
    codesign \
      --force \
      --sign - \
      --timestamp=none \
      --options runtime \
      --generate-entitlement-der \
      "$@" \
      "$target"
  fi
}

# Sparkle's helpers have distinct signing requirements. In particular, the
# Downloader XPC service carries an entitlement that must survive re-signing.
# Sign these leaves explicitly before sealing Sparkle.framework; `--deep` would
# incorrectly apply one entitlement set to every nested executable.
sparkle_framework="$app_path/Contents/Frameworks/Sparkle.framework"
if [ -d "$sparkle_framework" ]; then
  sparkle_version="$sparkle_framework/Versions/B"
  for helper in \
    "$sparkle_version/XPCServices/Installer.xpc" \
    "$sparkle_version/Autoupdate" \
    "$sparkle_version/Updater.app"; do
    if [ -e "$helper" ]; then
      echo "Signing Sparkle helper: $helper"
      sign_code "$helper"
    fi
  done

  sparkle_downloader="$sparkle_version/XPCServices/Downloader.xpc"
  if [ -e "$sparkle_downloader" ]; then
    echo "Signing Sparkle helper with preserved entitlements: $sparkle_downloader"
    sign_code "$sparkle_downloader" --preserve-metadata=entitlements
  fi

  echo "Signing Sparkle framework: $sparkle_framework"
  sign_code "$sparkle_framework"
fi

# Sign leaf code first so each containing bundle is sealed only after its
# contents are final. Sparkle is handled above because its helpers need
# entitlement-aware signing.
for frameworks_path in "$widget_path/Contents/Frameworks" "$app_path/Contents/Frameworks"; do
  if [ -d "$frameworks_path" ]; then
    while IFS= read -r -d '' nested_code; do
      if [ "$nested_code" = "$sparkle_framework" ]; then
        continue
      fi
      echo "Signing nested code: $nested_code"
      sign_code "$nested_code"
    done < <(find "$frameworks_path" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0)
  fi
done

sign_code "$cli_binary"
sign_code "$widget_path" --entitlements "$widget_entitlements"
sign_code "$app_path" --entitlements "$app_entitlements"

codesign --verify --strict --verbose=2 "$cli_binary"
codesign --verify --strict --verbose=2 "$widget_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
if [ -d "$sparkle_framework" ]; then
  codesign --verify --deep --strict --verbose=2 "$sparkle_framework"
fi

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/meterbar-release-entitlements.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

dump_entitlements() {
  local bundle="$1"
  local output="$2"
  local errors="$3"

  if ! codesign -d --entitlements - --xml "$bundle" > "$output" 2> "$errors"; then
    cat "$errors" >&2
    return 1
  fi
  if [ ! -s "$output" ]; then
    echo "Signed entitlement dump is empty for $bundle" >&2
    return 1
  fi
}

actual_app_entitlements="$temporary_directory/app.entitlements.plist"
actual_widget_entitlements="$temporary_directory/widget.entitlements.plist"
dump_entitlements "$app_path" "$actual_app_entitlements" "$temporary_directory/app.codesign.err"
dump_entitlements "$widget_path" "$actual_widget_entitlements" "$temporary_directory/widget.codesign.err"

python3 - \
  "$app_entitlements" "$actual_app_entitlements" \
  "$widget_entitlements" "$actual_widget_entitlements" <<'PY'
import plistlib
import sys

pairs = (
    ("app", sys.argv[1], sys.argv[2]),
    ("widget", sys.argv[3], sys.argv[4]),
)

for label, expected_path, actual_path in pairs:
    with open(expected_path, "rb") as expected_file:
        expected = plistlib.load(expected_file)
    with open(actual_path, "rb") as actual_file:
        actual = plistlib.load(actual_file)
    if actual != expected:
        raise SystemExit(
            f"{label} signed entitlements differ from source: "
            f"expected={expected!r} actual={actual!r}"
        )
    print(f"{label.capitalize()} signed entitlements match {expected_path}")
PY

# --- Session Wake: verify the embedded CLI wake path launches under the signed,
# hardened runtime. Hardened runtime + entitlements can change process-spawn
# behavior versus a debug build, so exercise the ACTUAL signed binary rather
# than trusting the unsigned test run. `--dry-run` spawns no claude process and
# mutates nothing, so this is safe and deterministic in CI.
wake_config_dir="$temporary_directory/wake-empty-claude"
mkdir -p "$wake_config_dir/projects"
if ! wake_json=$("$cli_binary" wake --dry-run --json --config-dir "$wake_config_dir"); then
  echo "Embedded CLI 'wake --dry-run' failed to launch from the signed bundle." >&2
  exit 1
fi
if ! printf '%s' "$wake_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["schemaVersion"] == 1, data
assert data["dryRun"] is True, data
assert data["outcome"] == "success", data
'; then
  echo "Embedded CLI wake did not emit the expected versioned dry-run response." >&2
  exit 1
fi
echo "Embedded CLI Session Wake dry-run verified from the signed bundle."

if [ -n "$signing_identity" ]; then
  echo "Developer ID nested signature integrity verified (identity: $signing_identity)."
  echo "Notarization and stapling run as separate release steps."
else
  echo "Ad-hoc nested signature integrity verified."
  echo "Developer ID, notarization, and authorized app-group access remain separate release prerequisites."
fi
