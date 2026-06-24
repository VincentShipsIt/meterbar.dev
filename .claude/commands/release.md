# /release — cut a MeterBar release and auto-deploy to Homebrew

Tag the current `master` as `vX.Y` so CI builds the app, publishes a GitHub
Release, and bumps the Homebrew cask in `VincentShipsIt/homebrew-tap` — all from
one tag push. Run this after the version-bumping PR has merged to `master`.

## Steps

1. **Preflight — clean, current master.**
   - `git fetch origin --prune`
   - Current branch must be `master` and `git status` clean. If not, stop and tell the user.
   - Local `master` must equal `origin/master` (fast-forward if behind; stop if diverged).

2. **Read the version to release** (whatever the merged PRs set):
   - `VERSIONS=$(grep 'MARKETING_VERSION' MeterBar.xcodeproj/project.pbxproj | sed -E 's/.*= *([0-9.]+).*/\1/' | sort -u)`
   - `[[ $(echo "$VERSIONS" | wc -l | tr -d ' ') -eq 1 ]] || { echo "MARKETING_VERSION entries differ:"; echo "$VERSIONS"; exit 1; }`
   - `VERSION=$(echo "$VERSIONS" | head -n 1)`
   - `TAG="v$VERSION"`

3. **Guard against double-release.**
   - If `git ls-remote --tags origin "$TAG"` returns the tag, STOP: this `MARKETING_VERSION` is already released. Tell the user to bump `MARKETING_VERSION` (all 4 configs in `MeterBar.xcodeproj/project.pbxproj`) in a PR, merge it, then re-run `/release`.

4. **Tag + push (this triggers everything).**
   - `git tag -a "$TAG" -m "MeterBar $TAG"`
   - `git push origin "$TAG"`
   - Fires `.github/workflows/release.yml`: build (unsigned) → publish GitHub Release with `MeterBar-$TAG.zip` + `.sha256` → its `update-homebrew` job calls `update-homebrew.yml`, which bumps `version` + `sha256` in the tap's `Casks/meterbar.rb`.

5. **Watch both jobs land.**
   - `gh run watch "$(gh run list --workflow=Release --limit 1 --json databaseId -q '.[0].databaseId')"`
   - Confirm the `build` AND `update-homebrew` jobs both succeed.
   - Verify the cask bumped: `gh api repos/VincentShipsIt/homebrew-tap/contents/Casks/meterbar.rb -q .content | base64 -d | grep -E 'version|sha256'`.

6. **Report** the release URL and the consumer command:
   - `brew update && brew upgrade --cask meterbar` (first-time: `brew install --cask vincentshipsit/tap/meterbar`).

## Notes
- Ships **unsigned/un-notarized** (signing deferred in #48); the cask's `postflight` strips the quarantine xattr so Gatekeeper won't block it.
- If the `update-homebrew` job ever fails alone, re-run it: `gh workflow run "Update Homebrew" -f version=vX.Y`.
- Never move or delete a published tag — cut a new patch version instead.
