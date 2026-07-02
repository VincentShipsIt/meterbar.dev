#!/usr/bin/env bash
set -euo pipefail

THRESHOLD="${COVERAGE_THRESHOLD:-80}"

swift test --enable-code-coverage

BIN_PATH="$(swift build --show-bin-path)"
if [ -z "$BIN_PATH" ]; then
  echo "Failed to resolve Swift build output path." >&2
  exit 1
fi

PROFDATA="$BIN_PATH/codecov/default.profdata"
if [ ! -f "$PROFDATA" ]; then
  echo "Coverage data not found at $PROFDATA" >&2
  exit 1
fi

TEST_BUNDLE="$(find "$BIN_PATH" -maxdepth 2 -name "*Tests.xctest" -print -quit)"
if [ -z "$TEST_BUNDLE" ]; then
  echo "Test bundle not found under $BIN_PATH." >&2
  exit 1
fi

TEST_BINARY_NAME="$(basename "$TEST_BUNDLE" .xctest)"
TEST_BINARY="$TEST_BUNDLE/Contents/MacOS/$TEST_BINARY_NAME"
if [ ! -f "$TEST_BINARY" ]; then
  echo "Test binary not found at $TEST_BINARY" >&2
  exit 1
fi

# JSON summary + jq instead of scraping the text report: the TOTAL row's last
# column is branch coverage ("-" when nothing is branch-instrumented), which
# made the old awk parse read "-%" and fail the gate even on a green suite.
COVERAGE_PERCENT="$(xcrun llvm-cov export "$TEST_BINARY" \
  -instr-profile "$PROFDATA" \
  -summary-only \
  -ignore-filename-regex ".*Tests.*" \
  | jq -r '.data[0].totals.lines.percent')"

if [ -z "$COVERAGE_PERCENT" ] || [ "$COVERAGE_PERCENT" = "null" ]; then
  echo "Failed to parse coverage report." >&2
  exit 1
fi

printf "Line coverage: %.2f%% (threshold: %s%%)\n" "$COVERAGE_PERCENT" "$THRESHOLD"

awk -v coverage="$COVERAGE_PERCENT" -v threshold="$THRESHOLD" 'BEGIN {exit !(coverage+0 >= threshold+0)}'
