---
name: release
description: Commit, push and ship a notarized Quickclean build. Asks which channel (alpha, beta, rc, stable) and version to release, proposing the next one from the latest tag, then tests, commits, pushes, archives, signs with Developer ID, notarizes, staples, builds the DMG and tags. Use when the user says "release", "ship", "cut a build", "notarize" or "/release".
---

# Release Quickclean

Ships a signed + notarized DMG from the current branch. Credentials: Developer ID Application:
David Barkan (L26TPPMPF3), notarytool keychain profile `notarytool` (override with `NOTARY_PROFILE`).

## 1. Preflight (read-only)

Run together:

```bash
git status --short; git branch --show-current; git log --oneline -1
git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo "none"
security find-identity -v -p codesigning | grep "Developer ID Application"
xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:-notarytool}" >/dev/null && echo notary-ok
```

Stop and tell the user if the Developer ID identity or the notary profile is missing
(fix: `xcrun notarytool store-credentials notarytool`).

## 2. Ask channel and version (always ask — never assume)

Parse the latest tag: `vX.Y.Z-<channel>` (alpha|beta|rc) or `vX.Y.Z` (stable). No tag → last = 0.0.0 alpha.

Compute proposals:
- **Next build, same channel**: X.Y.(Z+1) on the current channel (for stable: X.Y.(Z+1) stable).
- **Promote**: same X.Y.Z on the next channel (alpha → beta → rc → stable). Skip if already stable.
- **Next minor**: X.(Y+1).0 on the current channel.
- **Next major**: (X+1).0.0 on the current channel.

Ask both questions in ONE AskUserQuestion call:
1. "Which channel?" (header "Channel") — options alpha, beta, rc, stable; put the current channel first, marked "(Recommended)", unless promoting is clearly intended.
2. "Which version?" (header "Version") — the proposals above as options (label = version number, description = what it means, e.g. "Next alpha build after v0.0.1-alpha"). First option "(Recommended)" = next build on the same channel.

The user can type another version via "Other". Validate: `^[0-9]+\.[0-9]+\.[0-9]+$`, and the tag
(`vVERSION` for stable, `vVERSION-CHANNEL` otherwise) must not exist yet.

## 3. Commit

1. Update `Sources/QuickcleanCore/Version.swift` (`version` and `channel`).
2. Add a `CHANGELOG.md` entry at the top: `## VERSION (Channel) — YYYY-MM-DD`, summarizing
   `git log --oneline <last-tag>..HEAD` (skip chores; group as Added / Changed / Fixed).
3. Run `swift test`; stop on failure and show the failing tests.
4. Show the user any other uncommitted changes and propose a commit message for them; commit them first.
5. Commit the release: `chore(release): VERSION CHANNEL` (with the session's Co-Authored-By trailer).

## 4. Push

Push the current branch (`git push -u origin HEAD`). If the branch isn't `main`, ask whether to merge
into `main` first (fast-forward only) — releases are normally cut from `main`.

## 5. Build, sign, notarize

```bash
Scripts/release.sh VERSION CHANNEL
```

Run it in the background (notarization takes minutes) and wait for it to finish. It runs the tests,
archives, verifies hardened runtime + team, notarizes and staples the app, builds and signs the DMG,
notarizes and staples the DMG, runs Gatekeeper checks and creates the annotated tag locally.
On failure, show the relevant log from `build/release/<tag>/` and stop — do not retry blindly.

## 6. Publish

1. `git push origin <tag>`
2. Ask whether to publish a GitHub release with the DMG attached:
   ```bash
   gh release create <tag> build/release/<tag>/Quickclean-*.dmg --title "Quickclean VERSION (Channel)" \
     --notes-file <changelog section> [--prerelease  # for alpha, beta, rc]
   ```

Report: tag, DMG path, SHA-256, notarization IDs (from `build/release/<tag>/notary-*.json`), release URL if published.
