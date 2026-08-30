#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
launch_validator="$script_dir/verify-app-launch.sh"
fake_executable="$script_dir/fixtures/app-launch/fake-app-executable.sh"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/meterbar-app-launch-tests.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

# Builds a throwaway bundle around the fixture executable so the validator does
# the same CFBundleExecutable resolution it performs on a real signed app.
make_app() {
  local name="$1"
  local app_path="$temporary_directory/$name.app"

  mkdir -p "$app_path/Contents/MacOS"
  cp "$fake_executable" "$app_path/Contents/MacOS/MeterBar"
  chmod +x "$app_path/Contents/MacOS/MeterBar"
  cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>MeterBar</string>
  <key>CFBundleIdentifier</key>
  <string>dev.meterbar.app</string>
  <key>CFBundleShortVersionString</key>
  <string>1.8.2</string>
  <key>CFBundleVersion</key>
  <string>1.8.2</string>
</dict>
</plist>
PLIST

  printf '%s' "$app_path"
}

log_for() {
  printf '%s' "$temporary_directory/$1.log"
}

expect_rejection() {
  local label="$1"
  local scenario="$2"
  local expected_message="$3"
  shift 3
  local log_file
  log_file=$(log_for "$label")

  if METERBAR_LAUNCH_FIXTURE="$scenario" \
    "$launch_validator" "$@" > "$log_file" 2>&1; then
    echo "Launch smoke accepted the '$label' bundle." >&2
    cat "$log_file" >&2
    exit 1
  fi
  if ! grep -qF "$expected_message" "$log_file"; then
    echo "The '$label' bundle failed for an unexpected reason." >&2
    cat "$log_file" >&2
    exit 1
  fi
}

app=$(make_app MeterBar)

METERBAR_LAUNCH_FIXTURE=ok "$launch_validator" "$app"
METERBAR_LAUNCH_FIXTURE=ok "$launch_validator" "$app" 1.8.2
METERBAR_LAUNCH_FIXTURE=ok "$launch_validator" "$app" 1.8.2 1.8.2

# The reported defect: signatures verify, the process dies in dyld. The
# validator must fail and surface the loader diagnostic that explains why.
expect_rejection dyld-failure dyld-failure "exited with status 133" "$app"
if ! grep -qF "different Team IDs" "$(log_for dyld-failure)"; then
  echo "Launch smoke hid the dyld diagnostic that explains the failure." >&2
  exit 1
fi

expect_rejection silent-failure silent-failure "exited with status 3" "$app"
expect_rejection immediate-sigkill sigkill "was killed before completing" "$app"
if grep -qF "did not answer" "$(log_for immediate-sigkill)"; then
  echo "Launch smoke mislabeled an immediate kernel SIGKILL as a timeout." >&2
  cat "$(log_for immediate-sigkill)" >&2
  exit 1
fi
expect_rejection malformed malformed "is not one JSON document" "$app"
expect_rejection unknown-schema unknown-schema "schemaVersion must equal 1" "$app"
expect_rejection missing-marker not-a-smoke-response "launchSmoke must be true" "$app"

# Version agreement: a bundle that launches but reports someone else's build
# means the wrong artifact reached the signing step.
expect_rejection plist-short-drift short-version-mismatch "CFBundleShortVersionString" "$app"
expect_rejection plist-build-drift build-version-mismatch "CFBundleVersion" "$app"
# A self-consistent bundle still fails when it is not the version being released.
expect_rejection expected-short-drift ok "expected short version" "$app" 9.9.9
expect_rejection expected-build-drift ok "expected build version" "$app" 1.8.2 9999

# A decoupled nightly version pair is legitimate and must be accepted, but only
# when the launched bundle agrees with it.
nightly_app=$(make_app MeterBarNightly)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.8.3-nightly.42+a1b2c3d" \
  "$nightly_app/Contents/Info.plist" > /dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 1.8.3.42" \
  "$nightly_app/Contents/Info.plist" > /dev/null
METERBAR_LAUNCH_FIXTURE=nightly "$launch_validator" "$nightly_app" 1.8.3-nightly.42+a1b2c3d 1.8.3.42

# A wedged bundle must fail the gate quickly instead of hanging the release job.
(
  export METERBAR_LAUNCH_SMOKE_TIMEOUT=2
  expect_rejection hang hang "did not answer" "$app"
)

missing_executable_app=$(make_app MeterBarBroken)
rm "$missing_executable_app/Contents/MacOS/MeterBar"
expect_rejection missing-executable ok "not found or not executable" "$missing_executable_app"

echo "App launch smoke validator fixtures passed."
