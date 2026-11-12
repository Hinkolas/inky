# Changelog

## Unreleased

### Added

- A web address typed into the launcher is offered to be opened in the
  browser: `amazon.com`, `github.com/hinkolas/inky`, `localhost:3000`, or one
  spelled out with `https://`. Return opens it, ⌘↵ copies it as a link.
  Whatever ends in a top-level domain counts, so the name of a file such as
  `main.rs` is offered too, above the file itself. Settings → Browser switches
  it off.

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
