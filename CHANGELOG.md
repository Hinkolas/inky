# Changelog

## Unreleased

### Added

- Search Files, a command with a screen of its own: files and folders by
  name, with a preview of the selected one and what the Spotlight index knows
  about it. With nothing typed it lists what you opened lately. A menu, or
  Tab, narrows it down to folders, documents, images, videos, audio or code.
  Return opens a file, ⌘↵ shows it in Finder, ⌘C copies it and ⇧⌘C its path.
  What to search for can be typed along in the search, and the command can be
  chosen as a fallback.

### Changed

- Files are found by the words of their name in any order: “watcher folder”
  finds `FolderWatcher.swift`.
- Looking files up no longer holds the launcher up. Asking Spotlight about
  the files it found took up to 50 ms a search, during which nothing typed
  was shown.

## 0.1.0-alpha.6 — 2026-11-12

Copying a long text or a large image, and installing an application, no
longer hold Inky up: that is the sixth alpha.

### Changed

- Copying a long text no longer holds Inky up. Before, a text of a few
  megabytes was gone through in full to tell whether it was code, which took
  up to seconds, also while Inky was in the background. The clipboard history
  no longer tells code apart: what was listed as code is listed as text,
  and found under Text as before.
- Copying a large image no longer holds up the clipboard history while the
  image is kept: it is written first, and searching and scrolling go on
  meanwhile.
- An application that is installed or removed is found or gone within a few
  seconds, without the launcher having to be opened. Before, opening the
  launcher looked for applications again whenever it had not for half a
  minute.
- The clipboard history shows the images in its list from a small copy made
  for them, which it draws many times as quickly as the copy the selected
  image is shown by. Images copied before keep being shown by that.

## 0.1.0-alpha.5 — 2026-11-12

Fixes from a security review, for passwords, searches, pasting, uninstalling,
downloads and updates: that is the fifth alpha.

### Security

- A password copied from a password manager, kept because Settings →
  Clipboard asks to keep passwords, is marked as confidential again when it is
  copied or pasted from the history, so other clipboard managers leave it out
  as they did the first time.
- With Settings → General keeping no searches, the searches that ranked the
  results are no longer kept either, and those already kept are removed.
  Clearing the searches clears them too.
- Pasting from the clipboard history presses ⌘V only when the application it
  was meant for is still in front. Should another one have come forward
  meanwhile, Inky beeps and leaves the entry on the clipboard.
- Uninstalling an application offers to remove only files that are its own.
  An identifier that is too short to be its own, such as `com.example`,
  matches nothing, and for an identifier of Apple's only files named exactly
  after it count.
- What Inky downloads, a website's icon or the day's exchange rates, stops at
  a megabyte and half a minute, and an icon is not decoded when it is larger
  than 1024 pixels on a side.
- On the first launch, the clipboard is recorded only once the welcome window
  has been closed.
- An update is added to the update feed only once approved, and only when it
  is the app that the release's tag builds: the same version and build,
  signed with Inky's Developer ID and notarized. Building the disk image no
  longer has access to the signing certificate.

## 0.1.0-alpha.4 — 2026-11-12

A web address typed into the launcher opens in the browser.

### Added

- A web address typed into the launcher is offered to be opened in the
  browser: `amazon.com`, `github.com/hinkolas/inky`, `localhost:3000`, or one
  spelled out with `https://`. Return opens it, ⌘↵ copies it as a link, and ⌘N,
  or Create Quicklink under ⌘K, opens the editor for a new quicklink with the
  address filled in. Whatever ends in a top-level domain counts, so the name
  of a file such as `main.rs` is offered too, above the file itself.
  Settings → Browser switches it off.

## 0.1.0-alpha.3 — 2026-11-12

What is typed into the launcher is no longer lost when it closes.

### Added

- The launcher opens again where it was left. A click elsewhere, or the hotkey
  pressed again, puts it away as it is: the search, the selected result, what
  was typed into arguments, a command that is open. Opened again within a
  minute, it shows what it did. Settings → General sets how long, from never
  to always. Escape and ⌘W still close it for good.
- ↑ in the empty search brings back what was searched for before, newest
  first, with what was typed into a quicklink's arguments and the result that
  was selected. ↑ and ↓ then go through the earlier searches until something
  is typed; ⌃N and ⌃P move the selection meanwhile. A search is remembered
  when it is run, cleared with Escape, or closed with ⌘W, and the same search
  is listed once. Settings → General sets how many are kept, the last 100
  unless chosen otherwise, and clears them.

### Changed

- Files that were found stay listed while the same search is looked up again,
  as when an application was installed meanwhile, instead of going and
  coming back.

## 0.1.0-alpha.2 — 2026-11-11

Where the keyboard is in the launcher, which the first testers found unreliable.

### Fixed

- The launcher puts the keyboard into the field of the screen it shows and
  keeps it there, instead of leaving that to how soon macOS moves focus to a
  field that has just appeared. This covers opening the launcher right after
  closing it, opening the clipboard history, the quicklinks or another command
  with its hotkey, and renaming a pinned entry of the clipboard history.
- Going back to a list, as from editing a quicklink or from what uninstalling an
  application would remove, puts the keyboard into its filter again. Before,
  typing did nothing until the filter was clicked.
- In the quicklink editor, Tab goes from the link back to the name. Before, it
  left the keyboard with neither. Editing a quicklink puts the insertion point
  at the end of its link instead of selecting all of it.
- Typing is never lost to a launcher that is open: should the keyboard be with
  no field at all, the first key puts it back where it belongs.

## 0.1.0-alpha.1 — 2026-11-11

The first public alpha.

### Included

- An app icon made in Icon Composer, with a matching template icon in the menu bar.
- A disk image to download, with Inky and the Applications folder to drag it onto.
- Updates from GitHub Releases through Sparkle, with a signed feed and archives,
  for signed and notarized downloads. Every version is a download; Settings →
  General picks the Stable or the Beta update channel, and a pre-release starts
  on Beta. About and the update window show the whole version, such as
  0.1.0-alpha.1.
- A welcome window on first launch for the hotkey, features, clipboard history
  and its permissions, online lookups and startup.
- Application launching, fuzzy search, usage ranking and Spotlight file search.
- Quicklinks with arguments, clipboard and selected-text placeholders.
- Clipboard history for text, images and files, with pins and retention settings.
  Copies that password managers mark as confidential are left out by default.
- Calculator, unit and currency conversions, time queries and color conversion.
- System commands, per-command hotkeys, disabled commands and configurable fallbacks.
- Application uninstall review with selected files moved to the Trash.
- MIT source license, GeoNames attribution, contribution and security policies,
  and macOS test/build CI.

### Fixed during release preparation

- Failed clipboard database opens preserve saved databases, journals and images;
  a visible temporary history is used until the problem is resolved.
- Clipboard text containing embedded null characters is preserved when copied again.
- Uninstalling revalidates selected files against the current application inventory,
  rejecting unrelated files and data now shared by another installed copy.
- Failed GeoNames regeneration no longer truncates the bundled city list.
- Time arithmetic rejects durations that overflow or produce dates outside years 1–9999.

### Known limitations

- Requires a Mac with Apple silicon; Intel Macs are not supported.
- Clipboard history is stored without application-level encryption. Passwords
  copied from apps that do not mark them as confidential are kept. Disable the
  module if needed.
- Builds from source use an ad-hoc signature and do not update themselves.
  Signed, notarized, self-updating downloads start with this version.
- Application-data matching for uninstalling is heuristic; review the selected files.
- Currency conversions may use stale cached reference rates.
- Lua extensions are planned and cannot be installed yet.
