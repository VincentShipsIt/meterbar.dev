#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
  echo "usage: $0 <appcast.xml> <version> <archive-name> <download-url-prefix> [short-version]" >&2
  exit 64
fi

APPCAST=$1
# VERSION is Sparkle's ordering key (sparkle:version / CFBundleVersion).
# SHORT_VERSION is the display string (sparkle:shortVersionString). They match on
# stable, so SHORT_VERSION defaults to VERSION and existing 4-arg callers are unaffected.
VERSION=$2
ARCHIVE_NAME=$3
DOWNLOAD_URL_PREFIX=${4%/}/
SHORT_VERSION=${5:-$2}

xpath_string() {
  xmllint --xpath "string((//*[local-name()='enclosure'])[1]/@$1)" "$APPCAST"
}

xpath_namespaced_attribute() {
  xmllint --xpath "string((//*[local-name()='enclosure'])[1]/@*[local-name()='$1'])" "$APPCAST"
}

xpath_item_element() {
  xmllint --xpath "string((//*[local-name()='item'])[1]/*[local-name()='$1'][1])" "$APPCAST"
}

ACTUAL_VERSION=$(xpath_item_element version)
ACTUAL_SHORT_VERSION=$(xpath_item_element shortVersionString)
ACTUAL_SIGNATURE=$(xpath_namespaced_attribute edSignature)
ACTUAL_LENGTH=$(xpath_string length)
ACTUAL_URL=$(xpath_string url)

if [ "$ACTUAL_VERSION" != "$VERSION" ] || [ "$ACTUAL_SHORT_VERSION" != "$SHORT_VERSION" ]; then
  echo "appcast version mismatch: expected version=$VERSION short=$SHORT_VERSION, got $ACTUAL_VERSION / $ACTUAL_SHORT_VERSION" >&2
  exit 1
fi

if [ -z "$ACTUAL_SIGNATURE" ]; then
  echo "appcast enclosure is missing sparkle:edSignature" >&2
  exit 1
fi

if ! [[ "$ACTUAL_LENGTH" =~ ^[1-9][0-9]*$ ]]; then
  echo "appcast enclosure has invalid length: $ACTUAL_LENGTH" >&2
  exit 1
fi

if [ "$ACTUAL_URL" != "${DOWNLOAD_URL_PREFIX}${ARCHIVE_NAME}" ]; then
  echo "appcast URL mismatch: expected ${DOWNLOAD_URL_PREFIX}${ARCHIVE_NAME}, got $ACTUAL_URL" >&2
  exit 1
fi

echo "Sparkle appcast verified for $VERSION ($ARCHIVE_NAME)."
