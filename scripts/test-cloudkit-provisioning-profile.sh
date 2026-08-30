#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
validator="$script_dir/verify-cloudkit-provisioning-profile.sh"
profile="$script_dir/fixtures/cloudkit-profile-valid.plist"
entitlements="$script_dir/../MeterBar/MeterBar.entitlements"
matching_fingerprint="B2E09F94A8B2EEC2FB69C8ED645DFDE1F3558F0D"
mismatched_fingerprint="0000000000000000000000000000000000000000"

"$validator" "$profile" "$entitlements" "dev.meterbar.app" "$matching_fingerprint"

if "$validator" \
  "$profile" \
  "$entitlements" \
  "dev.meterbar.app" \
  "$mismatched_fingerprint" >/dev/null 2>&1; then
  echo "CloudKit profile validator accepted a different Developer ID certificate." >&2
  exit 1
fi

echo "CloudKit provisioning profile validation cases passed."
