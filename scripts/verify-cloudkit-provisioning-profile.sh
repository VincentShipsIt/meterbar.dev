#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "Usage: $0 PROFILE_PLIST REQUESTED_ENTITLEMENTS BUNDLE_ID SIGNING_CERT_SHA1" >&2
  exit 64
fi

profile_plist="$1"
requested_entitlements="$2"
bundle_id="$3"
signing_cert_sha1="$4"

/usr/bin/python3 - \
  "$profile_plist" \
  "$requested_entitlements" \
  "$bundle_id" \
  "$signing_cert_sha1" <<'PY'
import datetime
import hashlib
import plistlib
import re
import sys

profile_path, entitlements_path, bundle_id, signing_cert_sha1 = sys.argv[1:]
with open(profile_path, "rb") as source:
    profile = plistlib.load(source)
with open(entitlements_path, "rb") as source:
    requested = plistlib.load(source)

expiration = profile.get("ExpirationDate")
now = datetime.datetime.now(datetime.timezone.utc)
if not isinstance(expiration, datetime.datetime):
    raise SystemExit("Provisioning profile has no valid ExpirationDate")
if expiration.tzinfo is None:
    expiration = expiration.replace(tzinfo=datetime.timezone.utc)
if expiration <= now:
    raise SystemExit(f"Provisioning profile expired at {expiration.isoformat()}")
if profile.get("ProvisionsAllDevices") is not True:
    raise SystemExit("Provisioning profile is not a Developer ID distribution profile")

granted = profile.get("Entitlements", {})
application_id = granted.get("com.apple.application-identifier", "")
if not bundle_id or not application_id.endswith(f".{bundle_id}"):
    raise SystemExit(
        f"Provisioning profile application identifier {application_id!r} "
        f"does not authorize bundle {bundle_id!r}"
    )
team_prefix = application_id[: -(len(bundle_id) + 1)]
team_identifiers = profile.get("TeamIdentifier", [])
if not isinstance(team_identifiers, list) or team_prefix not in team_identifiers:
    raise SystemExit("Provisioning profile TeamIdentifier does not match its application identifier")

for key in (
    "com.apple.developer.icloud-container-identifiers",
    "com.apple.developer.icloud-services",
):
    expected = set(requested.get(key, []))
    actual = set(granted.get(key, []))
    if not expected or not expected.issubset(actual):
        raise SystemExit(
            f"Provisioning profile does not authorize {key}: "
            f"expected {sorted(expected)!r}, granted {sorted(actual)!r}"
        )

normalized_fingerprint = signing_cert_sha1.replace(":", "").upper()
if re.fullmatch(r"[0-9A-F]{40}", normalized_fingerprint) is None:
    raise SystemExit("Signing certificate fingerprint must be exactly 40 hexadecimal SHA-1 characters")
profile_fingerprints = {
    hashlib.sha1(certificate).hexdigest().upper()
    for certificate in profile.get("DeveloperCertificates", [])
    if isinstance(certificate, bytes)
}
if normalized_fingerprint not in profile_fingerprints:
    raise SystemExit(
        "Developer ID signing certificate is not authorized by the provisioning profile"
    )

print(
    "Developer ID profile authorizes "
    f"{bundle_id}, CloudKit, and signing certificate {normalized_fingerprint} "
    f"through {expiration.date().isoformat()}."
)
PY
