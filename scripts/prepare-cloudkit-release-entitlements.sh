#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "Usage: $0 PROFILE_PLIST SOURCE_ENTITLEMENTS BUNDLE_ID OUTPUT_PLIST" >&2
  exit 64
fi

profile="$1"
source_entitlements="$2"
bundle_id="$3"
output="$4"

python3 - "$profile" "$source_entitlements" "$bundle_id" "$output" <<'PY'
import plistlib
import sys

profile_path, source_path, bundle_id, output_path = sys.argv[1:]
with open(profile_path, "rb") as source:
    profile = plistlib.load(source)
with open(source_path, "rb") as source:
    entitlements = plistlib.load(source)

granted = profile.get("Entitlements", {})
if not isinstance(granted, dict):
    raise SystemExit("Provisioning profile Entitlements must be a dictionary")

application_id = granted.get("com.apple.application-identifier")
if not isinstance(application_id, str) or not application_id.endswith(f".{bundle_id}"):
    raise SystemExit(
        f"Provisioning profile application identifier {application_id!r} "
        f"does not authorize bundle {bundle_id!r}"
    )

team_prefix = application_id[: -(len(bundle_id) + 1)]
team_identifier = granted.get("com.apple.developer.team-identifier", team_prefix)
if team_identifier != team_prefix:
    raise SystemExit(
        f"Provisioning profile team identifier {team_identifier!r} "
        f"does not match application identifier prefix {team_prefix!r}"
    )

cloud_environment = granted.get("com.apple.developer.icloud-container-environment")
if cloud_environment != "Production":
    raise SystemExit(
        "Developer ID CloudKit releases require the Production container environment; "
        f"profile grants {cloud_environment!r}"
    )

# Only import the runtime identity keys MeterBar needs. Developer ID profiles
# can contain wildcard groups and unrelated grants that must never be copied
# wholesale into the app signature.
entitlements["com.apple.application-identifier"] = application_id
entitlements["com.apple.developer.team-identifier"] = team_identifier
entitlements["com.apple.developer.icloud-container-environment"] = cloud_environment

with open(output_path, "wb") as destination:
    plistlib.dump(entitlements, destination, fmt=plistlib.FMT_XML, sort_keys=True)
PY

plutil -lint "$output"
