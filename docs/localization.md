# Localization groundwork

Issue #392 is intentionally shipping in reviewable waves. The first phase adds
String Catalog infrastructure and localizes the quota/reset vertical slice; it
does not claim complete language support.

## Catalog ownership

- `MeterBar/Resources/Localizable.xcstrings` belongs to the app bundle.
- `MeterBarWidget/Resources/Localizable.xcstrings` belongs to the widget
  extension bundle. Widget copy must resolve here, not through the app bundle.
- `LocalizedUsageFormat` centralizes percentage, money-label, compact-duration,
  and count formatting shared by the two UI targets. Compact countdown units
  use Foundation's locale-aware `DateComponentsFormatter`; count labels use
  String Catalog plural variations.
- Provider/account/model names are runtime values and remain verbatim unless a
  future product decision explicitly defines a translated display name.

The English source catalog is the current shipping locale. Every new opaque key
must have an English value, a translator comment for ambiguous/interpolated
copy, and a resource-contract test when it is part of a critical flow.

## CLI compatibility boundary

Phase one does not localize CLI output. The existing English `UsageLimit`
properties remain available to the CLI while app/widget code opts into
`LocalizedUsageFormat`.

The following are protocol, not display copy, and must never be localized:

- command, subcommand, flag, provider, and quota-window tokens;
- JSON keys, enum values, error codes, and schema versions;
- exit codes and stdout-only JSON behavior.

If human-readable CLI output is localized later, locale selection must be
explicit and must not affect any `--json` document or stable command token.
`docs/cli-json-schema.md` remains the compatibility contract.

## Translation waves still open

1. Complete extraction and linguistic QA for Simplified Chinese (`zh-Hans`)
   and Japanese (`ja`) across the remaining app/settings/dashboard surfaces,
   then translate both app and widget catalogs together.
2. Repeat the same reviewed pass for German (`de`), French (`fr`), and Spanish
   (`es`). Do not copy machine translations into the catalogs as a bulk dump.
3. Before each language ships, verify screenshots at popover, dashboard,
   settings, and all widget-family widths; audit VoiceOver, dates, currencies,
   percentages, plural categories, truncation, and provider terminology.

## Verification

Compile each catalog before review:

```sh
xcrun xcstringstool compile MeterBar/Resources/Localizable.xcstrings --output-directory /tmp/meterbar-app-l10n
xcrun xcstringstool compile MeterBarWidget/Resources/Localizable.xcstrings --output-directory /tmp/meterbar-widget-l10n
```

Use Xcode's Double-Length and Right-to-Left pseudolanguages for the visual
layout pass. Automated tests cover catalog/resource contracts, plural-rule
presence, locale-aware countdown formatting, narrow quota rows, RTL direction,
and the flexible settings-row geometry.
