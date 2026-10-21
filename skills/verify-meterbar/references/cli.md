# CLI, routing, and packaging

## Scope

Public JSON in `docs/cli-json-schema.md`, recommendation-only workload routing, policy persistence, and universal helpers.

## Drive

```sh
swift test --filter 'RouteCLITests|WorkloadRouterTests|RoutingPolicyTests|RoutingPolicyEditorTests|PopoverRoutingLineTests'
swift build --package-path MeterBarCLI
```

Locate the executable with `swift build --package-path MeterBarCLI --show-bin-path`, then run `scripts/verify-cli-json-smoke.sh` with that executable path. The smoke validator checks actual usage/cost/doctor output; it does not exercise routing or policy writes. Use isolated policy/cache fixtures for routing and compare app/CLI decisions from identical inputs.

For packaging changes, run `scripts/build-universal-cli.sh` with an artifact output and scratch directory. Each required architecture must pass its own `lipo -verify_arch` check; a thin binary must fail the missing-slice check.

## Ready

JSON remains a single finite document with stable fields and exit codes. Missing, stale, malformed, exhausted, disallowed, or unsupported candidates are rejected. Saved unavailable accounts remain removable in the editor. Cancelled/obsolete popover reads cannot publish a replacement recommendation.

## Limits

`meterbar route` recommends; it makes no model call. Execution, HTTP/MCP exposure, and paid requests need their own product authorization. A universal build is not a signed/notarized release; follow `docs/sparkle-updates.md` and the release workflow for distribution evidence.
