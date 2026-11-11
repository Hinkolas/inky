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
- Choose and document the clipboard policy for this alpha. It currently keeps
  password-manager copies, including ones marked confidential. The README,
  SECURITY.md and release notes must describe the shipped behavior.
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
increment `CURRENT_PROJECT_VERSION` for every new distributed build. Record the
build number and exact source commit in the release notes. The app currently
shows the numeric version in About, so identify the alpha explicitly in the
release title and download filename.

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

`make release` creates an optimized, ad-hoc-signed local app. It does not produce
a Developer ID signature, notarize an app, or set up updates. A source-only alpha
can be published without a downloadable binary. If distributing a binary,
choose whether the alpha will be signed/notarized and state its actual status.

For a notarized download, use a Developer ID Application identity and the
appropriate team when archiving, notarize with Apple's notary service, staple
the result, and verify Gatekeeper acceptance on a clean Mac. Keep credentials
in the keychain or protected CI secrets; never in source files. Follow Apple's
[current notarization instructions](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Package only the intended Release app, its resource bundles and license
notices. Do not include local preferences, clipboard data, caches or Debug
sample data. Provide a SHA-256 checksum of each final download. Attach those
files to a GitHub release marked **pre-release**, tied to the tested commit.
Avoid marking the alpha as a stable/latest release.
