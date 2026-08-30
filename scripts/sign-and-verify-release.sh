#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 APP_PATH EXPECTED_SHORT_VERSION [EXPECTED_BUILD_VERSION]" >&2
  echo "EXPECTED_BUILD_VERSION defaults to EXPECTED_SHORT_VERSION (stable, where" >&2
  echo "CFBundleShortVersionString == CFBundleVersion). Pass both to verify a" >&2
  echo "nightly build whose display and ordering versions differ." >&2
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
# Short version is the human/display string (CFBundleShortVersionString, and what
# the embedded CLI reports). Build version is Sparkle's ordering key
# (CFBundleVersion). For stable they are identical; for nightly they differ.
expected_short="$2"
expected_build="${3:-$2}"
widget_path="$app_path/Contents/PlugIns/MeterBarWidgetExtension.appex"
app_binary="$app_path/Contents/MacOS/MeterBar"
widget_binary="$widget_path/Contents/MacOS/MeterBarWidgetExtension"
cli_binary="$app_path/Contents/Helpers/meterbar"
session_wake_agent_plist="$app_path/Contents/Library/LaunchAgents/dev.meterbar.app.session-wake.plist"
app_entitlements="$repository_root/MeterBar/MeterBar.entitlements"
widget_entitlements="$repository_root/MeterBarWidget/MeterBarWidget.entitlements"
embedded_profile="$app_path/Contents/embedded.provisionprofile"

if [ -n "$signing_identity" ] && [ ! -f "$embedded_profile" ]; then
  echo "Developer ID signing requires Contents/embedded.provisionprofile for CloudKit." >&2
  exit 1
fi

# Keep every version value free of shell metacharacters (they flow into echo and
# string comparisons downstream). Stable stays strictly canonical; nightly allows
# the decoupled forms: a dotted-integer build (e.g. 1.7.1.42) and a display short
# version drawn from a limited charset (e.g. 1.7.1-nightly.42+a1b2c3d).
if [ "$expected_build" = "$expected_short" ]; then
  if [[ ! "$expected_short" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "Expected version must match canonical MAJOR.MINOR.PATCH syntax." >&2
    exit 64
  fi
else
  if [[ ! "$expected_build" =~ ^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))+$ ]]; then
    echo "Nightly build version must be dotted integers (e.g. 1.7.1.42)." >&2
    exit 64
  fi
  if [[ ! "$expected_short" =~ ^[0-9A-Za-z.+-]+$ ]]; then
    echo "Nightly short version has unexpected characters: $expected_short" >&2
    exit 64
  fi
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

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/meterbar-release-entitlements.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

if [ -n "$signing_identity" ]; then
  decoded_profile="$temporary_directory/embedded-profile.plist"
  security cms -D -i "$embedded_profile" -o "$decoded_profile"
  bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_path/Contents/Info.plist")
  "$repository_root/scripts/verify-cloudkit-provisioning-profile.sh" \
    "$decoded_profile" \
    "$app_entitlements" \
    "$bundle_id" \
    "$signing_identity"
fi

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

echo "Expected short version: $expected_short"
echo "Expected build version: $expected_build"
echo "App version: $app_version"
echo "App build version: $app_build_version"
echo "CLI version: $cli_version"

if [ "$app_version" != "$expected_short" ]; then
  echo "App version $app_version does not match expected short version $expected_short." >&2
  exit 1
fi
if [ "$app_build_version" != "$expected_build" ]; then
  echo "App build version $app_build_version does not match expected build version $expected_build." >&2
  exit 1
fi
# The embedded CLI reports CFBundleShortVersionString, so it must equal the short version.
if [ "$cli_version" != "$expected_short" ]; then
  echo "CLI version $cli_version does not match expected short version $expected_short." >&2
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
    # Ad-hoc: deliberately NO `--options runtime`. Hardened runtime turns on
    # library validation, which requires the process and every library it maps
    # to share a Team ID. Ad-hoc signatures carry no Team ID, so an ad-hoc app
    # signed this way verifies perfectly and then dies in dyld the moment it
    # tries to map Sparkle.framework. Hardened runtime is a Developer ID and
    # notarization requirement; it belongs on the branch that can satisfy it.
    codesign \
      --force \
      --sign - \
      --timestamp=none \
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

# --- Launch smoke: every check above reads signatures at rest, and none of them
# notice a bundle dyld will refuse to load. Start the app for real and make it
# answer before AppKit does. This is what catches a signing option that verifies
# clean and then fails library validation at map time.
#
# CloudKit entitlements are restricted: macOS kills an ad-hoc process carrying
# them because no provisioning profile can authorize the entitlement. PR CI has
# no Apple credentials by design, so launch an otherwise-identical temporary
# copy whose top-level ad-hoc signature omits only those restricted grants. The
# real artifact above keeps its complete entitlement signature and parity check;
# Developer ID releases launch the real, provisioned artifact below.
launch_app_path="$app_path"
if [ -z "$signing_identity" ]; then
  smoke_entitlements="$temporary_directory/app-launch-smoke.entitlements.plist"
  restricted_entitlement_count=$(python3 - "$app_entitlements" "$smoke_entitlements" <<'PY'
import plistlib
import sys

source_path, output_path = sys.argv[1:3]
with open(source_path, "rb") as source_file:
    entitlements = plistlib.load(source_file)

restricted_keys = (
    "com.apple.developer.icloud-container-identifiers",
    "com.apple.developer.icloud-services",
)
expected_restricted = {
    "com.apple.developer.icloud-container-identifiers": ["iCloud.dev.meterbar.app"],
    "com.apple.developer.icloud-services": ["CloudKit"],
}
actual_restricted = {key: entitlements.get(key) for key in restricted_keys}
if actual_restricted != expected_restricted:
    raise SystemExit(
        "ad-hoc launch filtering requires the exact MeterBar CloudKit grants: "
        f"expected={expected_restricted!r} actual={actual_restricted!r}"
    )
removed = sum(entitlements.pop(key, None) is not None for key in restricted_keys)

with open(output_path, "wb") as output_file:
    plistlib.dump(entitlements, output_file, fmt=plistlib.FMT_XML, sort_keys=True)

print(removed)
PY
  )

  if [ "$restricted_entitlement_count" -gt 0 ]; then
    launch_app_path="$temporary_directory/MeterBarLaunchSmoke.app"
    ditto "$app_path" "$launch_app_path"
    sign_code "$launch_app_path" --entitlements "$smoke_entitlements"
    codesign --verify --deep --strict --verbose=2 "$launch_app_path"

    actual_smoke_entitlements="$temporary_directory/app-launch-smoke.actual.plist"
    dump_entitlements \
      "$launch_app_path" \
      "$actual_smoke_entitlements" \
      "$temporary_directory/app-launch-smoke.codesign.err"
    python3 - "$smoke_entitlements" "$actual_smoke_entitlements" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as expected_file:
    expected = plistlib.load(expected_file)
with open(sys.argv[2], "rb") as actual_file:
    actual = plistlib.load(actual_file)
if actual != expected:
    raise SystemExit(
        "ad-hoc launch-smoke entitlements differ from the restricted-free source: "
        f"expected={expected!r} actual={actual!r}"
    )
PY
    echo "Ad-hoc launch copy omits only CloudKit's restricted entitlements."
  fi
fi

"$script_dir/verify-app-launch.sh" "$launch_app_path" "$expected_short" "$expected_build"

if [ -n "$signing_identity" ]; then
  echo "Developer ID nested signature integrity verified (identity: $signing_identity)."
  echo "Notarization and stapling run as separate release steps."
else
  echo "Ad-hoc signing verified: nested signature integrity and entitlement parity."
  echo "Launch verified on an otherwise-identical copy without restricted CloudKit grants."
  echo "This is NOT release-grade: ad-hoc bundles carry no Team ID and are signed"
  echo "without hardened runtime, so library validation is not exercised here."
  echo "Developer ID, hardened runtime, notarization, and authorized app-group access"
  echo "remain separate release prerequisites verified only on the signed path."
fi
