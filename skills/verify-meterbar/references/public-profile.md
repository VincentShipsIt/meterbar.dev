# Public-profile lifecycle

## Scope

`PublicProfileStore`, client, coordinator, document allowlist, and `docs/public-profile-contract.md`. The hosted page/API live in a separate repository.

## Drive

```sh
swift test --filter 'PublicProfileStoreTests|PublicProfileClientTests|PublicProfileDocumentTests|PublicProfilePresentationTests'
```

Use fixture clients and disposable identities by default. Live publication acceptance uses a synthetic disposable profile only when the task authorizes that external write; verify deletion and remove the fixture afterward. Reading the app's Share page does not require publishing the user's usage.

## Ready

Opt-out is the default. Payloads contain only the contract's allowlist. Failed deletion survives relaunch, retains the old identity/key, and cannot republish during a reset. A new identity is minted only after the old deletion is confirmed. Demo mode never publishes.

## Limits

A local test does not prove the deployed page, API ownership, no-store behavior, OG card deletion, or a social network's cache. Report those as separate acceptance results. Real account names, identity keys, projects, and usage are not synthetic test data.
