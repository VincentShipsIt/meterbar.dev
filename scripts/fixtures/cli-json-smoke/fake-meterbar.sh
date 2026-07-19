#!/usr/bin/env bash
set -euo pipefail

scenario="${METERBAR_CLI_SMOKE_FIXTURE:-cache-missing}"
command_name="${1:-}"
format="${2:-}"

if [ "$format" != "--json" ]; then
  echo "Expected --json." >&2
  exit 64
fi

case "$scenario:$command_name" in
  cache-missing:usage)
    printf '%s\n' \
      '{"schemaVersion":1,"error":{"code":"usage_cache_missing","message":"No cached metrics found."}}'
    ;;
  cache-missing:cost)
    printf '%s\n' \
      '{"schemaVersion":1,"error":{"code":"cost_cache_missing","message":"No cached cost found."}}'
    ;;
  cache-missing:doctor)
    printf '%s\n' \
      '[{"provider":"Codex CLI","overall":"warn","healthy":false,"checks":[{"id":"auth","title":"Signed in","level":"warn","detail":"Sign-in not verified."}]}]'
    ;;
  data:usage)
    printf '%s\n' \
      '{"schemaVersion":1,"providers":[{"provider":"codex","displayName":"OpenAI Codex","lastUpdated":"2026-07-17T00:00:00Z","windows":[{"kind":"weekly","used":25,"total":100,"percentUsed":25,"percentLeft":75,"quotaBand":"healthy","estimated":false}]}]}'
    ;;
  data:cost)
    printf '%s\n' \
      '{"schemaVersion":1,"lastScannedAt":"2026-07-17T00:00:00Z","period":{"requestedDays":30,"coveredDays":1,"isTruncated":true},"providers":[{"provider":"codex","displayName":"OpenAI Codex","inputTokens":100,"outputTokens":20,"cacheReadTokens":5,"totalTokens":125,"estimatedCostUSD":0.01}],"totalCostUSD":0.01,"totalTokens":125}'
    ;;
  data:doctor)
    echo "fixture diagnostic remains on stderr" >&2
    printf '%s\n' \
      '[{"provider":"Codex CLI","overall":"pass","healthy":true,"checks":[{"id":"auth","title":"Signed in","level":"pass","detail":"Signed in.","recovery":null}]}]'
    ;;
  malformed:usage)
    printf '%s\n' 'debug output that contaminates stdout'
    printf '%s\n' \
      '{"schemaVersion":1,"error":{"code":"usage_cache_missing","message":"No cached metrics found."}}'
    ;;
  malformed:cost)
    METERBAR_CLI_SMOKE_FIXTURE=cache-missing "$0" "$@"
    ;;
  malformed:doctor)
    METERBAR_CLI_SMOKE_FIXTURE=cache-missing "$0" "$@"
    ;;
  secret-field:usage)
    METERBAR_CLI_SMOKE_FIXTURE=cache-missing "$0" "$@"
    ;;
  secret-field:cost)
    METERBAR_CLI_SMOKE_FIXTURE=cache-missing "$0" "$@"
    ;;
  secret-field:doctor)
    printf '%s\n' \
      '[{"provider":"Codex CLI","overall":"pass","healthy":true,"accessToken":"must-not-ship","checks":[]}]'
    ;;
  *)
    echo "Unknown fixture scenario or command: $scenario:$command_name" >&2
    exit 64
    ;;
esac
