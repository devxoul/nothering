# nothering

iPhone app + Mac menu bar app, system extension and CLI that route the Mac's traffic through the iPhone's cellular connection. Built with Tuist, signed with fastlane match. The iPhone app ships to TestFlight; the Mac app and CLI ship as notarized zips on GitHub Releases.

## Build

```bash
tuist generate --no-open   # creates Nothering.xcworkspace
```

Schemes: `NotheringiOS` (iPhone app), `NotheringMenuBar` (Mac app, embeds the extension), `NotheringMac` (`nothering` CLI), `ProxyCore` / `PhoneLink` (libraries + tests).

The version lives in `Project.swift` (`CFBundleShortVersionString`). The build number is not committed: fastlane passes it in through `TUIST_BUILD_NUMBER` at release time.

## Release

"Release the next version" means: decide the version, write TestFlight notes, trigger the **Release** workflow, and watch it.

### 1. Decide the version

- If the user gives an exact version (e.g. `0.3.0`), use it as-is.
- Otherwise look at the changes since the last release:
  ```bash
  git fetch --tags
  git log $(git describe --tags --abbrev=0 2>/dev/null || git rev-list --max-parents=0 HEAD)..origin/main --oneline
  ```
  - **minor** (`x.Y.0`): new features, UI changes, new behaviors
  - **patch** (`x.y.Z`): bug fixes, performance, refactors, dependency updates
- **Never bump major.** Only the owner does that.
- If there are no tags yet, the first release is the version already in `Project.swift`.
- Tags have no `v` prefix (`0.2.0`, not `v0.2.0`).

### 2. Write the TestFlight notes

Rewrite `fastlane/release_notes.txt`, commit it, and **push to `main`** before triggering; the workflow builds from `main`. It becomes TestFlight's "What to Test".

- Written for testers: what changed and what to try. Lead with the most important change.
- Plain text, English, a few short lines. No emoji, no markdown.
- Nothing user-facing? Say so: "Internal cleanup only. Nothing new to test, just check that the proxy still connects."

The GitHub Release notes are auto-generated from merged PRs, so don't write those.

### 3. Trigger and watch

```bash
gh workflow run release.yml -f version=X.Y.Z
sleep 5
gh run watch "$(gh run list --workflow release.yml --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status
```

Report the result with the GitHub Release URL (`gh release view X.Y.Z --json url -q .url`).

### What the workflow does

1. Validates `x.y.z` and that the tag doesn't exist yet.
2. `fastlane bump version:X.Y.Z` sets the version in `Project.swift` and commits locally.
3. `fastlane release` picks one build number (latest TestFlight build + 1) for both apps, then:
   - builds the Mac app and CLI, signs with Developer ID, notarizes, and zips them to `build/fastlane/`;
   - builds the iPhone app and uploads it to TestFlight (internal testers).
4. Only after all of that succeeds: pushes the bump commit to `main`, tags `X.Y.Z`, and creates the GitHub Release with `Nothering-X.Y.Z.zip` and `nothering-cli-X.Y.Z.zip` attached.

### If a release fails

Don't re-run the same version: a TestFlight build may already be uploaded. Find the cause from the run log (`gh run view <id> --log-failed`), fix it on `main`, and release the **next patch** version. Failed versions stay skipped.

### Required GitHub secrets

| Secret | Value |
| --- | --- |
| `MATCH_PASSWORD` | Passphrase for the `devxoul/nothering-match` repo |
| `MATCH_GITHUB_PAT` | GitHub PAT with read-only `Contents` access to `devxoul/nothering-match` |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect API issuer ID |
| `APP_STORE_CONNECT_API_KEY_P8_BASE64` | `base64` of the `.p8` key file |

## Signing

Certificates and profiles live in the private `devxoul/nothering-match` repo, encrypted with `MATCH_PASSWORD`. CI runs match read-only. Creating or renewing them happens locally only; the Developer ID certificate needs the account holder's Apple ID (`MATCH_USERNAME`), not the API key.

Release builds swap the Network Extension entitlements for their `-systemextension` variants, since Developer ID profiles only allow those.
