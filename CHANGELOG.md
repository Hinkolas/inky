# Changelog

## 0.1.0-alpha.1 — 2026-11-11

The first public alpha.

### Included

- An app icon made in Icon Composer, with a matching template icon in the menu bar.
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
