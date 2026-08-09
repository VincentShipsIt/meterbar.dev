#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$ROOT_DIR/.build/tmp" "$ROOT_DIR/.build/module-cache"

TMPDIR="$ROOT_DIR/.build/tmp" \
CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache" \
SWIFT_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache" \
swiftc -parse-as-library "$ROOT_DIR/scripts/render-readme-screenshots.swift" \
  "$ROOT_DIR/Packages/MeterBarShared/Sources/MeterBarShared/ServiceType.swift" \
  "$ROOT_DIR/Packages/MeterBarShared/Sources/MeterBarShared/UsageStatus.swift" \
  "$ROOT_DIR/Packages/MeterBarShared/Sources/MeterBarShared/QuotaBands.swift" \
  "$ROOT_DIR/Packages/MeterBarShared/Sources/MeterBarShared/UsageLimit.swift" \
  "$ROOT_DIR/Packages/MeterBarShared/Sources/MeterBarShared/UsageAmountFormatting.swift" \
  "$ROOT_DIR/Packages/MeterBarShared/Sources/MeterBarShared/UsageMetrics.swift" \
  -o "$ROOT_DIR/.build/render-readme-screenshots"

"$ROOT_DIR/.build/render-readme-screenshots"

printf "\nGenerated:\n- %s\n- %s\n" \
  "$ROOT_DIR/docs/screenshots/menubar.png" \
  "$ROOT_DIR/docs/screenshots/widget-medium.png"
