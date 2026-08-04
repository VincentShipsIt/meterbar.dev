#!/usr/bin/env bash
set -euo pipefail

# Proves a bundle can actually start.
#
# `codesign --verify --deep --strict` only inspects signatures at rest, so a
# bundle whose frameworks dyld will refuse to map still verifies clean. That is
# how an ad-hoc bundle signed with hardened runtime once passed the release gate
# and then died on launch with "different Team IDs" for Sparkle. Running the real
# executable is the only check that covers the loader.
#
# The app answers `--launch-smoke` before AppKit starts: one JSON document, then
# exit. Reaching that output means every embedded framework was mapped and every
# signature was accepted by the kernel, which is the property being gated.

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 APP_PATH [EXPECTED_SHORT_VERSION [EXPECTED_BUILD_VERSION]]" >&2
  exit 64
fi

app_path="$1"
expected_short_version="${2:-}"
expected_build_version="${3:-}"
launch_timeout="${METERBAR_LAUNCH_SMOKE_TIMEOUT:-90}"

if [ ! -d "$app_path" ]; then
  echo "App bundle not found: $app_path" >&2
  exit 1
fi

info_plist="$app_path/Contents/Info.plist"
if [ ! -f "$info_plist" ]; then
  echo "App bundle has no Info.plist: $info_plist" >&2
  exit 1
fi

executable_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$info_plist")
plist_short_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$info_plist")
plist_build_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$info_plist")

app_binary="$app_path/Contents/MacOS/$executable_name"
if [ ! -f "$app_binary" ] || [ ! -x "$app_binary" ]; then
  echo "App executable not found or not executable: $app_binary" >&2
  exit 1
fi

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/meterbar-app-launch.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

stdout_file="$temporary_directory/launch.stdout"
stderr_file="$temporary_directory/launch.stderr"

# macOS ships no `timeout(1)`, so the probe runs in the background behind a
# watchdog. A bundle that blocks (a stuck singleton, a window-server prompt on a
# headless runner) must fail the gate instead of wedging the release job.
"$app_binary" --launch-smoke > "$stdout_file" 2> "$stderr_file" &
launch_pid=$!

(
  sleep "$launch_timeout"
  kill -9 "$launch_pid" 2> /dev/null || true
) &
watchdog_pid=$!

launch_status=0
wait "$launch_pid" || launch_status=$?
kill "$watchdog_pid" 2> /dev/null || true
wait "$watchdog_pid" 2> /dev/null || true

report_launch_diagnostics() {
  if [ -s "$stderr_file" ]; then
    echo "--- launch stderr ---" >&2
    cat "$stderr_file" >&2
    echo "--- end launch stderr ---" >&2
  fi
  if [ -s "$stdout_file" ]; then
    echo "--- launch stdout ---" >&2
    cat "$stdout_file" >&2
    echo "--- end launch stdout ---" >&2
  fi
}

# SIGKILL is how the watchdog fires, and also how the kernel reports a code
# signature the loader refused, so name the timeout explicitly.
if [ "$launch_status" -eq 137 ] && [ ! -s "$stdout_file" ]; then
  echo "$app_path did not answer --launch-smoke within ${launch_timeout}s." >&2
  report_launch_diagnostics
  exit 1
fi

if [ "$launch_status" -ne 0 ]; then
  echo "$app_path exited with status $launch_status instead of completing --launch-smoke." >&2
  echo "The bundle's signatures may verify while dyld still refuses to load it." >&2
  report_launch_diagnostics
  exit 1
fi

python3 - \
  "$stdout_file" \
  "$plist_short_version" \
  "$plist_build_version" \
  "$expected_short_version" \
  "$expected_build_version" <<'PY'
import json
import sys


def fail(message):
    raise SystemExit(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_constant(value):
    fail(f"non-standard JSON numeric constant: {value}")


def require(condition, message):
    if not condition:
        fail(message)


(
    stdout_path,
    plist_short_version,
    plist_build_version,
    expected_short_version,
    expected_build_version,
) = sys.argv[1:6]

try:
    with open(stdout_path, "r", encoding="utf-8") as stream:
        document = json.load(
            stream,
            parse_constant=reject_constant,
            object_pairs_hook=unique_object,
        )
except (OSError, UnicodeError, json.JSONDecodeError) as error:
    fail(f"launch smoke stdout is not one JSON document: {error}")

require(isinstance(document, dict), "launch smoke response must be a JSON object")
require(
    document.get("schemaVersion") == 1,
    "launch smoke response schemaVersion must equal 1",
)
require(
    document.get("launchSmoke") is True,
    "launch smoke response launchSmoke must be true",
)
require(
    isinstance(document.get("bundleIdentifier"), str) and document["bundleIdentifier"],
    "launch smoke response bundleIdentifier must be a non-empty string",
)

for field in ("shortVersion", "buildVersion"):
    require(
        isinstance(document.get(field), str) and document[field],
        f"launch smoke response {field} must be a non-empty string",
    )

# The launched process reads its own Info.plist, so disagreement here means the
# bundle that ran is not the bundle that was signed.
require(
    document["shortVersion"] == plist_short_version,
    "launched bundle reported short version "
    f"{document['shortVersion']!r} but its CFBundleShortVersionString is {plist_short_version!r}",
)
require(
    document["buildVersion"] == plist_build_version,
    "launched bundle reported build version "
    f"{document['buildVersion']!r} but its CFBundleVersion is {plist_build_version!r}",
)

if expected_short_version:
    require(
        document["shortVersion"] == expected_short_version,
        f"launched bundle reported short version {document['shortVersion']!r} "
        f"but the expected short version is {expected_short_version!r}",
    )
if expected_build_version:
    require(
        document["buildVersion"] == expected_build_version,
        f"launched bundle reported build version {document['buildVersion']!r} "
        f"but the expected build version is {expected_build_version!r}",
    )

print(
    f"Launch smoke passed: {document['bundleIdentifier']} "
    f"{document['shortVersion']} ({document['buildVersion']}) started and answered."
)
PY

if [ -s "$stderr_file" ]; then
  echo "Launch smoke wrote diagnostics to stderr:"
  cat "$stderr_file"
fi
