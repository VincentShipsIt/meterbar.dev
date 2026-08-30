#!/usr/bin/env bash
set -euo pipefail

# Stands in for a signed MeterBar executable answering `--launch-smoke`.
# `METERBAR_LAUNCH_FIXTURE` selects the failure the release gate must catch.
scenario="${METERBAR_LAUNCH_FIXTURE:-ok}"

if [ "${1:-}" != "--launch-smoke" ]; then
  echo "Expected --launch-smoke." >&2
  exit 64
fi

ok_document='{"buildVersion":"1.8.2","bundleIdentifier":"dev.meterbar.app","launchSmoke":true,"schemaVersion":1,"shortVersion":"1.8.2"}'

case "$scenario" in
  ok)
    printf '%s\n' "$ok_document"
    ;;
  nightly)
    printf '%s\n' \
      '{"buildVersion":"1.8.3.42","bundleIdentifier":"dev.meterbar.app","launchSmoke":true,"schemaVersion":1,"shortVersion":"1.8.3-nightly.42+a1b2c3d"}'
    ;;
  dyld-failure)
    # The real defect: hardened runtime plus ad-hoc signing, so library
    # validation refuses to map Sparkle and the process dies before main().
    cat >&2 <<'DYLD'
dyld[4242]: Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
  Reason: tried: '/Applications/MeterBar.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle' (code signature in <...> not valid for use in process: mapping process and mapped file (non-platform) have different Team IDs)
DYLD
    exit 133
    ;;
  silent-failure)
    exit 3
    ;;
  sigkill)
    # Mirrors AMFI killing an ad-hoc process whose restricted entitlement has
    # no authorizing provisioning profile.
    kill -9 "$$"
    ;;
  malformed)
    printf '%s\n' 'debug output that contaminates stdout'
    printf '%s\n' "$ok_document"
    ;;
  short-version-mismatch)
    printf '%s\n' \
      '{"buildVersion":"1.8.2","bundleIdentifier":"dev.meterbar.app","launchSmoke":true,"schemaVersion":1,"shortVersion":"9.9.9"}'
    ;;
  build-version-mismatch)
    printf '%s\n' \
      '{"buildVersion":"9999","bundleIdentifier":"dev.meterbar.app","launchSmoke":true,"schemaVersion":1,"shortVersion":"1.8.2"}'
    ;;
  unknown-schema)
    printf '%s\n' \
      '{"buildVersion":"1.8.2","bundleIdentifier":"dev.meterbar.app","launchSmoke":true,"schemaVersion":2,"shortVersion":"1.8.2"}'
    ;;
  not-a-smoke-response)
    # A future build that answers the flag without running the probe must not
    # be mistaken for a successful launch.
    printf '%s\n' \
      '{"buildVersion":"1.8.2","bundleIdentifier":"dev.meterbar.app","schemaVersion":1,"shortVersion":"1.8.2"}'
    ;;
  hang)
    # A bundle that blocks (window server prompt, stuck singleton) must trip the
    # watchdog instead of wedging the release job.
    sleep 900
    ;;
  *)
    echo "Unknown launch fixture scenario: $scenario" >&2
    exit 64
    ;;
esac
