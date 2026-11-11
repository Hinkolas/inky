# Contributing to Inky

Bug reports and focused improvements are welcome. For a larger feature or a
change to how the launcher works, discuss it in an issue first.

## Build and check

Use macOS 15 or later and Xcode 26 or later, with Xcode selected as the active
developer directory. There are no external Swift package dependencies.

```sh
make build
make test
make release
```

The core tests use temporary data and a separate pasteboard. They must not
change the user's real clipboard, uninstall installed apps, or call live
network services. Use injected fetch and Trash implementations in tests.
For manual testing, a Debug build accepts `--data <folder>`; see the README.
The argument isolates application data and the clipboard, but does not isolate
all macOS preferences or permissions. Use a separate macOS account when testing
first launch and permissions.

## Changes

Keep changes focused and follow the existing Swift style. Put parsing, storage
and search behavior in InkyCore, and AppKit/SwiftUI presentation in Inky. Add a
regression test for a bug fix where it can verify meaningful behavior. Explain
what changed and how you checked it in the pull request.

Update user-facing documentation when behavior changes. New dependencies or
assets need compatible licenses and an entry in `THIRD_PARTY_NOTICES.md`.
Keep generated data changes separate from unrelated code changes; `make places`
requires network access and updates the bundled GeoNames snapshot.

Do not commit credentials, signing keys, user databases, private URLs or
screenshots containing personal information. Report vulnerabilities according
to [SECURITY.md](SECURITY.md), not in public issues.

Contributions are made under the project's [MIT license](LICENSE), except for
third-party material that retains its separately documented license.
Be respectful and specific when discussing changes.
