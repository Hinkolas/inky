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
Keep `MARKETING_VERSION` in the project at the numeric `0.1.0`; the release
workflow refuses a tag whose numeric part differs, and builds the app with the
tag's whole version as `CFBundleShortVersionString`, so About and Sparkle's
update window show `0.1.0-alpha.1`. A version with a suffix (`-alpha.N`,
`-beta.N`, `-rc.N`) is a pre-release, and the app starts on the beta update
channel when it is one.

The workflow sets `CURRENT_PROJECT_VERSION` to the number of commits on the
tagged commit, which Sparkle compares to decide what is newer, across both
channels. It refuses a tag that is not on `main`, where that number only grows.

On a clean checkout:

```sh
make test
make build
xcodebuild -project Inky.xcodeproj -scheme Inky \
  -derivedDataPath build -configuration Release build
```

Inky supports Apple silicon only: `lipo -archs` on the executable prints
`arm64`. Check that
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
- The minimum supported macOS version (15) and a current macOS version.

Update CHANGELOG.md with the release date and actual known limitations after
these checks pass. Do not describe untested versions or architectures as tested.

## Distribution

Every version is a download that updates itself, pre-releases included.
`make release` creates an optimized, ad-hoc-signed local app that does not
update itself.

Pushing a `v*` tag runs `.github/workflows/release.yml`, which archives the
Apple silicon app, signs it with the Developer ID certificate, notarizes and
staples it, zips it, and drafts a GitHub release with the zip and a SHA-256
checksum, as a pre-release when the tag has a suffix. Nothing reaches users
until the draft is published.

Publishing a release runs `.github/workflows/update-feed.yml`. It adds the
release to the update feed, signs the whole feed with the EdDSA key, saves it
on the `appcast` branch and deploys that branch to GitHub Pages, where
installed apps read `https://hinkolas.github.io/inky/appcast.xml`. Releases
are items without a channel, which every installed app accepts; pre-releases
are items in the `beta` channel, which only apps set to the Beta update
channel accept. The feed keeps the latest three items of each channel; their
downloads stay on the GitHub releases. A release's notes in Sparkle's update
window are its published notes on GitHub.

- Mark a release as a pre-release on GitHub exactly when its tag has a suffix;
  the feed workflow refuses a mismatch. Do not change it after publishing.
- Publish releases in the order of their tags. Unpublishing or deleting a
  release does not take it out of the feed: remove its item on the `appcast`
  branch and run the feed workflow for the latest release again, which signs
  the feed anew.
- Never edit `appcast.xml` by hand without re-signing it, and never replace a
  published archive: Sparkle rejects it, and every installed copy then reports
  that the update could not be checked.
- To add a release again, for example after a failed deployment, run the
  workflow by hand with its tag. A release already in the feed is left as it is.

### One-time setup

1. **Update key.** Done on 2026-11-11; the public key is in the project.
   Build once so Sparkle is resolved, then run
   `build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account inky`.
   It keeps the private key in your login keychain under the account `inky`
   and prints the public key. Put the public key in `INKY_UPDATE_PUBLIC_KEY`
   for both configurations in `Inky.xcodeproj` and commit it. Export the
   private key with `generate_keys --account inky -x sparkle-private-key`,
   store it as the `SPARKLE_PRIVATE_KEY` secret (`gh secret set
   SPARKLE_PRIVATE_KEY < sparkle-private-key`), keep a copy in a password
   manager, and delete the file. Never lose it: installed apps only accept
   updates signed with the key they were built with.
2. **Developer ID.** Done on 2026-11-11. In the Apple Developer Program,
   create a Developer ID Application certificate. Xcode's Manage
   Certificates refused with "only the Account Holder" for the account
   holder, so use the website: Keychain Access → Certificate Assistant →
   Request a Certificate From a Certificate Authority (saved to disk), upload
   it at developer.apple.com → Certificates → Developer ID Application (G2
   Sub-CA), and add the downloaded `.cer` to the login keychain. Export the
   certificate with its private key as a `.p12`, and store
   `base64 -i cert.p12` as `DEVELOPER_ID_P12`, its password as
   `DEVELOPER_ID_P12_PASSWORD`, and the team ID (in parentheses in the
   certificate's name) as `APPLE_TEAM_ID`.
3. **Notarization.** Done on 2026-11-11. Create an App Store Connect API key with the Developer
   role and store `base64 -i AuthKey.p8` as `NOTARY_API_KEY_P8`, with
   `NOTARY_API_KEY_ID` and `NOTARY_API_ISSUER_ID`.
4. **GitHub Pages.** Once the repository is public, set Settings → Pages →
   Source to "GitHub Actions"
   (`gh api -X POST repos/Hinkolas/inky/pages -f build_type=workflow`). Then
   let the release tags deploy: Settings → Environments → `github-pages` →
   Deployment branches and tags → add the tag rule `v*`
   (`gh api -X POST repos/Hinkolas/inky/environments/github-pages/deployment-branch-policies -f name='v*' -f type=tag`).
   Without it, the feed workflow, which runs for the release's tag, is
   refused with "not allowed to deploy to github-pages due to environment
   protection rules". The `appcast` branch is created by the first run.
5. Protect the secrets with a `release` environment that requires your
   approval, if more people get write access to the repository.

### Each release

1. Finish the CHANGELOG section for the version, headed `## 0.1.0-alpha.1`
   followed by a space or nothing: the workflow uses it as the notes of the
   draft.
2. Tag the tested commit on `main` and push the tag.
3. Download the draft's zip on a clean Mac: it opens without a Gatekeeper
   warning, `spctl --assess --type execute -v Inky.app` accepts it, and About
   shows the whole version.
4. Publish the draft, and wait for the feed workflow to finish. Its summary
   links the deployed feed; the new item is at its top.
5. On a Mac with the previous version on the matching channel, Check for
   Updates offers it, installs it and relaunches. A Mac on Stable is not
   offered a pre-release.

Keep credentials in the keychain or protected CI secrets, never in source
files. See Apple's
[notarization instructions](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
and Sparkle's [publishing guide](https://sparkle-project.org/documentation/publishing/).
