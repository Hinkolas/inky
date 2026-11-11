# Alpha preparation review

Reviewed on 2026-11-11, starting from `9b74ef4`.
Changes are prepared locally on `chore/prepare-public-alpha`. This is a focused
release review, not a complete security audit or proof that every code path is
free of bugs.

## Confirmed issues fixed

### High: clipboard recovery could destroy recoverable data

`ClipboardStore` previously treated every open failure as corruption, replaced
an earlier `history.unreadable.sqlite`, removed WAL/SHM files, and opened a new
empty database against the old images folder. Startup cleanup then considered
those old images stray. A lock or another temporary open failure could therefore
turn into permanent loss of clipboard data.

The store now leaves saved files in place and uses an in-memory database with
an isolated temporary image directory. Newer schema versions are also refused
without replacement. The clipboard screen and settings explain the temporary
state. Regression tests cover unreadable data, existing recovery copies and
images, locked databases, and newer schema versions.

### Medium: uninstall validation accepted unrelated Library files

The final validation checked only whether a file's parent was a known Library
folder. It did not check whether the file belonged to the chosen app. The normal
UI supplies matched files, so this was an incomplete safety boundary rather
than a demonstrated external exploit. It also failed to account for a second
copy of an application installed after its review was opened.

The uninstaller now rebuilds the eligible list from the current installed-app
inventory and requires every selected item to be in it before moving anything.
Noncanonical application paths are rejected, and protected applications yield
no removal candidates. Regression tests reject unrelated files in valid Library
folders and shared data after another copy is installed. This remains heuristic
matching, not proof of ownership or protection against a hostile process racing
filesystem changes.

### Medium: embedded null characters truncated clipboard text

SQLite writes used null-terminated strings and reads used `String(cString:)`.
Text after an embedded null was lost when an entry was restored. Both operations
now use explicit UTF-8 byte lengths; a regression test round-trips a null,
accented text and an emoji through the clipboard store.

### Medium: huge time offsets produced invalid answers

Inputs such as `time in 1e308 years` overflowed when converted to seconds;
other enormous finite offsets reached date formatters as unsupported dates.
Regression tests reproduced invalid answers. Time arithmetic now rejects
non-finite durations and results outside years 1–9999 before continuing with
calendar arithmetic or formatting. No crash was observed in the tested formatter
on this machine.

### Low: failed place-list generation could erase the bundled data

`make places` redirected directly into the tracked TSV before the generator
succeeded. It now generates into the build directory and replaces the TSV only
after success. The generator rejects input with no valid city records.

## Decisions and follow-up work

- **Clipboard confidentiality:** resolved. Copies marked confidential by
  password managers are now left out by default, and unpinned ones an earlier
  build kept are deleted when recording starts. Settings → Clipboard History
  can keep them again. Unmarked secrets still cannot be reliably detected, and
  encrypting kept ones is a follow-up.
- **Public commit metadata:** existing commits expose a personal email address.
  The maintainer accepted publishing the history as it is.
- **Binary distribution:** the app is currently ad-hoc signed. Developer ID
  signing, notarization and automatic updates are not configured. Decide between
  a source-only alpha and a binary release, and accurately describe its status.
- **Security reporting:** the private repository's reporting endpoint returned
  404. Enable and verify private vulnerability reporting when making the repo
  public; the new policy cannot turn the GitHub setting on by itself.
- **Persistence errors:** the JSON stores and several clipboard mutations still
  suppress write failures with `try?`. Disk-full/permission failures can leave
  the UI suggesting a change was saved. A follow-up should return explicit
  operation outcomes and show recoverable errors without discarding prior data.
- **Download bounds:** network requests have a timeout but download entire
  responses before validating them. Byte and decoded-image limits would improve
  resilience against oversized icon/rate responses.

## Clean-code assessment

The module boundary, dependency injection for network/Trash operations, actor
isolation for SQLite, and existing core tests are useful foundations. No obvious
abandoned TODO/FIXME blocks, committed build products, credentials matching the
checked patterns, or release-enabled debug launch controls were found. Sample
clipboard data and debug launch helpers are intentionally behind `#if DEBUG`;
removing them would remove useful development tools. Compatibility readers for
older quicklink/hotkey settings remain useful to existing installations.

The README now explicitly says third-party extensions are not implemented.
The unsupported `init(coder:)` traps are normal for programmatically created
windows, and the forced Accessibility cast checks the Core Foundation type first;
those are not obvious crashes to remove mechanically.

`LauncherModel.swift` is the largest concentration of responsibilities: search,
navigation, commands, quicklinks, uninstall and clipboard actions. Splitting it
along those existing feature boundaries is sensible future maintenance, but a
large refactor immediately before the alpha would add risk. Similar focused
extraction could help `SettingsPanes.swift` and `ClipboardBrowser.swift` as they
grow. There is no need for a repo-wide style rewrite before this release.

## Public-repository preparation

Added the MIT license selected by the maintainer, third-party notices, a bundled
GeoNames attribution file, SECURITY.md, CONTRIBUTING.md, issue and PR templates,
a CI workflow, a draft changelog and a release checklist. Xcode bundles the
project license and third-party notices. The GeoNames notice travels with its
Swift package resources. `Package.resolved` is no longer ignored, so future
external dependencies can have a committed lockfile; there are none today.

GeoNames' own [dataset documentation](https://download.geonames.org/export/dump/readme.txt)
identifies CC BY 4.0. The notices identify the source, license and modifications,
as required by the [license summary](https://creativecommons.org/licenses/by/4.0/).
System frameworks and runtime-fetched icons/rates are distinguished from bundled
source/data; this review does not establish ownership of code copied from sources
that have not been identified in the repository.

## Verification

- Baseline: 198 core tests passed. New regressions reproduced the storage,
  validation, null-character and time-range problems before their fixes.
- Final: 203 tests in 20 suites passed, including five extreme time-input cases.
- Debug build and universal Release build checked with Xcode 27.2 on this Mac.
- Release executable contains both `arm64` and `x86_64`; its signature is ad-hoc.
- Release executable checked for the Debug launch flags; they are absent. Both
  builds emitted only the App Intents metadata notice about the unused framework.
- A fresh derived-data build includes LICENSE, THIRD_PARTY_NOTICES.md,
  GeoNames-NOTICE.txt and places.tsv in the app/resource bundle.
- Empty/valid GeoNames fixtures checked without downloading or replacing the
  bundled dataset. Xcode project syntax, CI YAML parsing and whitespace checked.
- Pattern scan of 258 historical file versions reachable from local branches,
  tags and remote-tracking refs found no matches for common private keys,
  GitHub/AWS/Slack tokens, quoted secret assignments or the local home path.
  This is not a comprehensive secret scanner or a review of GitHub-hosted logs,
  issues, attachments and other repository content.

GitHub CI has been prepared but not run remotely. Xcode 26.2, the minimum macOS
version, Intel execution, first-launch permissions, signing/notarization and a
full interactive smoke test still require release validation. Build success
alone does not validate those. Follow RELEASING.md before publishing.
