# Sparkle Update Setup

MeterBar direct-download builds use Sparkle 2.9.4. Homebrew remains a supported, independent update path.

## One-time signing setup

1. Resolve the Xcode package and locate Sparkle's tools under the Derived Data `SourcePackages/artifacts/sparkle/Sparkle/bin/` directory.
2. Run `generate_keys --account meterbar` once, then export it with `generate_keys --account meterbar -x /secure/path/meterbar-sparkle-private-key`. Back up that private key outside the repository.
3. Add the printed base64 public key to the `release` GitHub environment as the Actions variable `SPARKLE_PUBLIC_ED_KEY`.
4. Add the exported private-key contents to the `release` GitHub environment as the Actions secret `SPARKLE_PRIVATE_ED_KEY`.

The release workflow fails before building if either value is absent. Never commit the private key or pass it as a command-line argument; CI pipes the secret to `generate_appcast --ed-key-file -` over standard input.

## Release behavior

For a canonical `vMAJOR.MINOR.PATCH` tag, `.github/workflows/release.yml`:

1. embeds the public key and stable GitHub Releases feed URL in `MeterBar.app`;
2. signs, notarizes, and staples the universal app;
3. creates the final ZIP;
4. uses Sparkle's `generate_appcast` to add the ZIP's EdDSA signature;
5. validates the version, archive URL, length, and signature; and
6. publishes the ZIP, SHA-256 file, and `appcast.xml` in the same GitHub Release.

The app reads the feed from `https://github.com/VincentShipsIt/meterbar.dev/releases/latest/download/appcast.xml`. Automatic checks default off and begin only after explicit consent in Settings. A manual **Check Now** remains available.

## Verification

Before tagging, run:

```bash
swift test --filter SparkleUpdateTests
shellcheck scripts/verify-appcast.sh scripts/sign-and-verify-release.sh
actionlint .github/workflows/release.yml
```

After publishing, install the prior Sparkle-enabled release, choose **Settings → General → Check Now**, and complete the update. Versions before v1.7.1 do not contain Sparkle and require one manual upgrade.

Treat key rotation as a release migration. Follow Sparkle's official key-rotation procedure and never change the app bundle identifier (`dev.meterbar.app`).
