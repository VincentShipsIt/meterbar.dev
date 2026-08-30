#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
validator="$script_dir/verify-cloudkit-provisioning-profile.sh"
entitlement_preparer="$script_dir/prepare-cloudkit-release-entitlements.sh"
profile="$script_dir/fixtures/cloudkit-profile-valid.plist"
entitlements="$script_dir/../MeterBar/MeterBar.entitlements"
mismatched_fingerprint="0000000000000000000000000000000000000000"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/meterbar-cloudkit-profile.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

make_certificate() {
  local common_name="$1"
  local output_prefix="$2"
  openssl req \
    -x509 \
    -newkey rsa:2048 \
    -nodes \
    -days 1 \
    -subj "/CN=$common_name/OU=C76R5DRH64/O=MeterBar Fixture" \
    -keyout "$output_prefix.key" \
    -out "$output_prefix.pem" >/dev/null 2>&1
  openssl x509 -in "$output_prefix.pem" -outform DER -out "$output_prefix.der"
}

profile_with_certificate() {
  local certificate="$1"
  local output="$2"
  python3 - "$profile" "$certificate" "$output" <<'PY'
import plistlib
import sys

profile_path, certificate_path, output_path = sys.argv[1:]
with open(profile_path, "rb") as source:
    profile = plistlib.load(source)
with open(certificate_path, "rb") as source:
    profile["DeveloperCertificates"] = [source.read()]
with open(output_path, "wb") as destination:
    plistlib.dump(profile, destination)
PY
}

certificate_fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha1 \
    | cut -d= -f2 \
    | tr -d ':'
}

developer_prefix="$temporary_directory/developer-id"
developer_profile="$temporary_directory/developer-id-profile.plist"
make_certificate "Developer ID Application: Fixture (C76R5DRH64)" "$developer_prefix"
profile_with_certificate "$developer_prefix.der" "$developer_profile"
matching_fingerprint=$(certificate_fingerprint "$developer_prefix.pem")

"$validator" "$developer_profile" "$entitlements" "dev.meterbar.app" "$matching_fingerprint"

prepared_entitlements="$temporary_directory/prepared-entitlements.plist"
"$entitlement_preparer" \
  "$developer_profile" \
  "$entitlements" \
  "dev.meterbar.app" \
  "$prepared_entitlements"
python3 - "$prepared_entitlements" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    entitlements = plistlib.load(source)

expected = {
    "com.apple.application-identifier": "C76R5DRH64.dev.meterbar.app",
    "com.apple.developer.team-identifier": "C76R5DRH64",
    "com.apple.developer.icloud-container-environment": "Production",
    "com.apple.developer.icloud-container-identifiers": ["iCloud.dev.meterbar.app"],
    "com.apple.developer.icloud-services": ["CloudKit"],
    "com.apple.security.application-groups": ["group.dev.meterbar.app"],
}
for key, value in expected.items():
    if entitlements.get(key) != value:
        raise SystemExit(f"Prepared entitlement {key} was {entitlements.get(key)!r}, expected {value!r}")
PY

development_profile="$temporary_directory/development-profile.plist"
python3 - "$developer_profile" "$development_profile" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    profile = plistlib.load(source)
profile["Entitlements"]["com.apple.developer.icloud-container-environment"] = "Development"
with open(sys.argv[2], "wb") as destination:
    plistlib.dump(profile, destination)
PY
if "$entitlement_preparer" \
  "$development_profile" \
  "$entitlements" \
  "dev.meterbar.app" \
  "$temporary_directory/development-entitlements.plist" >/dev/null 2>&1; then
  echo "CloudKit release entitlement preparation accepted the Development environment." >&2
  exit 1
fi

if "$validator" \
  "$developer_profile" \
  "$entitlements" \
  "dev.meterbar.app" \
  "$mismatched_fingerprint" >/dev/null 2>&1; then
  echo "CloudKit profile validator accepted a different Developer ID certificate." >&2
  exit 1
fi

distribution_prefix="$temporary_directory/apple-distribution"
distribution_profile="$temporary_directory/apple-distribution-profile.plist"
make_certificate "Apple Distribution: Fixture (C76R5DRH64)" "$distribution_prefix"
profile_with_certificate "$distribution_prefix.der" "$distribution_profile"
distribution_fingerprint=$(certificate_fingerprint "$distribution_prefix.pem")
if "$validator" \
  "$distribution_profile" \
  "$entitlements" \
  "dev.meterbar.app" \
  "$distribution_fingerprint" >/dev/null 2>&1; then
  echo "CloudKit profile validator accepted a non-Developer-ID certificate." >&2
  exit 1
fi

echo "CloudKit provisioning profile validation cases passed."
