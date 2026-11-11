# Releasing Inky

The first intended tag is `v0.1.0-alpha.1`. This document prepares a release;
no release is published by the build commands or CI workflow.

## Before making the repository public

- Confirm the MIT copyright owner and third-party notices cover the source and
  bundled data. Keep the license and notices in distributed apps and archives.
- Review tracked files and reachable Git history for credentials, private URLs,
  personal data and assets without redistribution rights. Rotate any exposed
  credential; deleting its current file is not enough. Inspect the branch and
  tags being published, not local orchestration/checkpoint refs.
- Review the repository's issues, pull requests, Actions logs and other GitHub
  content before changing visibility; those are outside a source-code audit.
- Keep the clipboard policy in the README, SECURITY.md and release notes in
  line with the shipped behavior. Copies marked confidential by password
  managers are left out by default.
- Configure GitHub Actions for the repository and run CI on the release commit.
  The workflow uses Xcode 26.2 on `macos-15`; update the pin if that image retires it.
- After changing visibility, enable private vulnerability reporting under the
  repository's security settings and verify the form linked in SECURITY.md
  from another account. A SECURITY.md file alone does not enable this feature.
  See [GitHub's instructions](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository).
- Enable available secret scanning and push protection; consider requiring CI
  and pull requests for changes to `main`.

Changing visibility, pushing, creating a release and publishing artifacts are
separate maintainer actions. Local preparation does not perform them.

## Version and validation

Use `0.1.0-alpha.1` in the release title and `v0.1.0-alpha.1` for its Git tag.
Keep `MARKETING_VERSION` / `CFBundleShortVersionString` at the numeric `0.1.0`;
the release workflow refuses a tag whose numeric part differs. It sets
`CURRENT_PROJECT_VERSION` to the number of commits on the tagged commit, which
Sparkle compares to decide what is newer; tag releases on `main` so it only
grows. The app shows the numeric version in About, so identify a pre-release
explicitly in the release title and download filename.

On a clean checkout:

```sh
make test
make build
xcodebuild -project Inky.xcodeproj -scheme Inky \
  -derivedDataPath build -configuration Release \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
```

Confirm both architectures in the executable with `lipo -archs`. Check that
`LICENSE` and `THIRD_PARTY_NOTICES.md` are present in `Inky.app/Contents/Resources`,
and that the InkyCore resource bundle contains `GeoNames-NOTICE.txt` and
`places.tsv`.

Run a manual smoke test in a separate macOS account, including:

- First launch, the launcher hotkey, reopening from Finder and launch at login.
- Accessibility and pasteboard access denied, requested and granted.
- Application launching, quicklinks with arguments, disabled commands and hotkeys.
- Clipboard text/image/file capture, paste, pinning, filtering and retention.
- Uninstalling only disposable test apps and files; canceling a permission prompt.
- Offline calculator use, unavailable icon/rate services, light/dark appearance,
  reduced motion, and keyboard navigation.
- The minimum supported macOS version (15), a current macOS version, and both
  Apple silicon and Intel if distributing a universal binary. Cross-compiling
  an architecture does not prove that it runs on that hardware.

Update CHANGELOG.md with the release date and actual known limitations after
these checks pass. Do not describe untested versions or architectures as tested.

## Distribution

Pre-releases are source-only: tag them, publish a GitHub pre-release, and let
people build them. `make release` creates an optimized, ad-hoc-signed local app
that does not update itself.

Releases are downloads that update themselves. Pushing a `v*` tag runs
`.github/workflows/release.yml`, which archives a universal app, signs it with
the Developer ID certificate, notarizes and staples it, zips it, writes a
Sparkle appcast signed with the EdDSA key, and drafts a GitHub release with the
zip, `appcast.xml` and a SHA-256 checksum. Nothing reaches users until the
draft is published.

Installed apps read `releases/latest/download/appcast.xml`. GitHub's "latest"
is the newest published release that is neither a draft nor a pre-release, so
pre-releases never reach downloaded apps. Never publish a release whose
appcast or archive was edited after the workflow signed them: Sparkle rejects
it, and every installed copy then reports that the update could not be checked.

### One-time setup

1. **Update key.** Build once so Sparkle is resolved, then run
   `build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`. It
   keeps the private key in your login keychain and prints the public key. Put
   the public key in `INKY_UPDATE_PUBLIC_KEY` for both configurations in
   `Inky.xcodeproj` and commit it. Export the private key with
   `generate_keys -x sparkle-private-key`, store its contents as the
   `SPARKLE_PRIVATE_KEY` secret, and delete the file. Back the key up: an app
   can only be updated by archives signed with the key it was built with.
2. **Developer ID.** In the Apple Developer Program, create a Developer ID
   Application certificate, export it with its private key as a `.p12`, and
   store `base64 -i cert.p12` as `DEVELOPER_ID_P12`, its password as
   `DEVELOPER_ID_P12_PASSWORD`, and the team ID as `APPLE_TEAM_ID`.
3. **Notarization.** Create an App Store Connect API key with the Developer
   role and store `base64 -i AuthKey.p8` as `NOTARY_API_KEY_P8`, with
   `NOTARY_API_KEY_ID` and `NOTARY_API_ISSUER_ID`.
4. Protect the secrets with a `release` environment that requires your
   approval, if more people get write access to the repository.

### Each release

1. Finish the CHANGELOG section for the version: the workflow uses it as the
   release notes, in the draft and in Sparkle's update window.
2. Tag the tested commit on `main` and push the tag.
3. Download the draft's zip on a clean Mac: it opens without a Gatekeeper
   warning, and `spctl --assess --type execute -v Inky.app` accepts it.
4. Publish the draft. On a Mac with the previous release, Check for Updates
   offers it, installs it and relaunches.

Keep credentials in the keychain or protected CI secrets, never in source
files. See Apple's
[notarization instructions](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
and Sparkle's [publishing guide](https://sparkle-project.org/documentation/publishing/).
