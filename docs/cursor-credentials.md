# Cursor credential access

Cursor owns sign-in and token refresh. MeterBar reads `cursorAuth/accessToken`
from Cursor's `state.vscdb` with SQLite read-only access. It does not read the
refresh token, modify Cursor's storage or ACLs, or persist decrypted credentials.

Plaintext JWTs remain supported. Current encrypted values use
`cursor-safe-storage:v1:` followed by the base64 output of Electron's
`safeStorage.encryptString`. The codec was verified in Cursor's bundled
`cursorAuthTokenStorageCodec.js` on 2026-10-27.

On macOS, MeterBar supports the `v10` envelope used by Chromium OSCrypt:
PBKDF2-HMAC-SHA1 with salt `saltysalt`, 1003 iterations, a 16-byte key,
AES-128-CBC with a 16-space IV and PKCS#7 padding. It reads only the existing
Keychain generic password with service `Cursor Safe Storage`, account `Cursor Key`.
Unknown envelopes and failed decryption are rejected. The resolved value must
have a JWT subject before any dashboard request is sent.

The underlying contracts are documented in [Electron safeStorage](https://www.electronjs.org/docs/latest/api/safe-storage)
and [Chromium's macOS OSCrypt implementation](https://github.com/chromium/chromium/blob/140.0.7339.0/components/os_crypt/sync/os_crypt_mac.mm).
This is compatibility with Cursor's local implementation, not a versioned public
Cursor authentication API.

All automatic reads suppress both Keychain authentication UI and the legacy
process-wide Keychain dialog. **Settings → Providers → xAI → Connect Cursor** is
an explicit interactive read. Its notice explains the Keychain prompt before it
can appear. Choosing **Always Allow** permits later reads by the signed app;
unsigned development builds and the CLI may have different Keychain access.
Neither a missing key nor denied access causes MeterBar to create a key or
fall back to an unencrypted credential file.

Database failures, missing tokens, Keychain access requirements, unsupported or
undecryptable credentials, malformed JWTs and dashboard authentication rejection
remain separate diagnostics. Transient SQLite busy, journal and open failures
get at most three read-only attempts with a bounded busy timeout. MeterBar never
uses an immutable database view or copies the main file without its WAL, which
could silently use an outdated token while Cursor runs.

A failed read retains the last successful usage reading. Authentication and
local data failures suppress the quota-reset countdown in the error hover;
a weekly reset cannot fix credential access.

Offline regression tests use synthetic encrypted data generated independently
with Python PBKDF2 and OpenSSL. SQLite tests read the token with a WAL writer
open, during an uncommitted write and after that writer closes. These establish
storage compatibility; they do not substitute for an authorized live account
check on the affected Cursor version.
