#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
smoke_validator="$script_dir/verify-cli-json-smoke.sh"
fake_cli="$script_dir/fixtures/cli-json-smoke/fake-meterbar.sh"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/meterbar-cli-json-smoke-tests.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

METERBAR_CLI_SMOKE_FIXTURE=cache-missing "$smoke_validator" "$fake_cli"
METERBAR_CLI_SMOKE_FIXTURE=data "$smoke_validator" "$fake_cli"

if METERBAR_CLI_SMOKE_FIXTURE=malformed \
  "$smoke_validator" "$fake_cli" > "$temporary_directory/malformed.log" 2>&1; then
  echo "CLI JSON smoke accepted stdout contaminated with non-JSON diagnostics." >&2
  exit 1
fi
if ! grep -qF "usage stdout is not one JSON document" "$temporary_directory/malformed.log"; then
  echo "Malformed stdout fixture failed for an unexpected reason." >&2
  cat "$temporary_directory/malformed.log" >&2
  exit 1
fi

if METERBAR_CLI_SMOKE_FIXTURE=secret-field \
  "$smoke_validator" "$fake_cli" > "$temporary_directory/secret-field.log" 2>&1; then
  echo "CLI JSON smoke accepted a secret-bearing doctor field." >&2
  exit 1
fi
if ! grep -qF "forbidden secret-bearing field 'accessToken'" "$temporary_directory/secret-field.log"; then
  echo "Secret-bearing doctor fixture failed for an unexpected reason." >&2
  cat "$temporary_directory/secret-field.log" >&2
  exit 1
fi

echo "CLI JSON smoke validator fixtures passed."
