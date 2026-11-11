# Changelog

## 0.1.0-alpha.1 — Unreleased

First public alpha, in preparation.

### Included

- Application launching, fuzzy search, usage ranking and Spotlight file search.
- Quicklinks with arguments, clipboard and selected-text placeholders.
- Clipboard history for text, images and files, with pins and retention settings.
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

- Clipboard history stores password-manager copies, including confidential ones,
  without application-level encryption. Disable the module if needed.
- Signing, notarization and automatic updates are not provided by `make release`.
  Local builds use an ad-hoc signature.
- Application-data matching for uninstalling is heuristic; review the selected files.
- Currency conversions may use stale cached reference rates.
- Lua extensions are planned and cannot be installed yet.
