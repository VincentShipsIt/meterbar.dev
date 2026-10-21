# Token and cost totals

## Scope

`TokenCount`, `SafeAccumulate`, scanners, API usage aggregation, `TokenCost`, and their persisted/CLI projections.

## Drive

```sh
swift test --filter 'NumericSafetyTests|CostAccumulationSafetyTests|CostScanCorpusTests|CostScanFileCacheSafetyTests|UsageReportTests|CLIJSONOutputTests'
```

Include the changed scanner's fixture tests. Feed a corrupt/saturated event followed by a normal event through the real aggregation path; checking the parser alone misses a later fold that traps.

## Ready

Token counts saturate without wrapping. Non-finite or overflowing cost input cannot poison JSON or erase healthy persisted records. Token ratios use unsaturated floating operands where a ratio is intended. Currency and request-count observations keep their different units.

## Limits

Do not infer a provider price, currency, allowance, or missing usage from a test fixture. Pricing updates require their own source verification. Loop/file counters are not token fields merely because they are integers.
