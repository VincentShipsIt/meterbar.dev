# Quota, cache, and native UI

## Scope

`UsageMetrics`, `QuotaReading`, `UsageCache`, provider parsers, `ProviderSnapshotBuilder`, and widget presentation. Account state is keyed by `ProviderAccount`; provider-wide summaries are display projections.

## Drive

```sh
swift test --filter 'ProviderPayloadDriftTests|QuotaReadingTests|UsageCacheTests|MetricsCodecTests|CachedMetricsContractTests|CachedMetricsReplicaContractTests|ProviderSnapshotTests|WidgetPresentationTests'
```

Add the affected provider tests. Use synthetic fixtures for parser verification. `ProviderPayloadDriftTests` switches exhaustively over `ServiceType`: every provider needs a readable control and mutations that cannot produce a reading. Both xAI sources are covered.

For an interaction change, build and drive the development app (`dev.meterbar.app.debug`). Move between adjacent provider cards, through the gap into the hover panel, and onto the footer. Check one hover owner, stable main-panel geometry, no unsolicited scrolling, and dismissal when entering a different card. Inspect light/dark and a narrow window when layout changed. The screenshot renderer's separate website publishing path is documented in `docs/readme-screenshots.md`.

## Ready

Measured zero, estimated quota, idle/unsupported, and malformed data remain distinct. A bad blocking window cannot disappear in a way that makes routing eligible. Account A and provider-wide data cannot answer account B's lookup. Healthy persisted entries survive a bad sibling. Credits without a denominator remain balances.

## Limits

A fixture pass does not verify an unofficial endpoint or a live reset time. Use a separately authorized real-account read for that acceptance item, retain only sanitized evidence, and report unavailable accounts honestly. Native screenshots of another build do not validate the changed binary.
