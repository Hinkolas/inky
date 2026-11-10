# Inky

A fast, open source launcher for macOS. Press a hotkey anywhere, type, and act:
launch apps, open links with arguments, calculate, find files, run system
commands. No accounts, no subscriptions, no telemetry.

Inky is at an early stage. The core works and is meant to be built on.

## What it does today

- **Applications**: fuzzy search over installed apps, ranked by how often and how recently you pick them.
- **Quicklinks**: named shortcuts to websites, folders and app links. Placeholders such as `{argument name="Query"}`, `{clipboard}` and `{selection}` are filled in when the link opens; arguments are typed right in the search bar.
- **Calculator**: type `128 * 3 + 4` or `sqrt(2) ^ 10`, press Return to copy the result.
- **File search**: files and folders by name, from the Spotlight index.
- **System commands**: lock, sleep, restart, shut down, log out, empty trash, toggle dark mode.

The default hotkey is ⌥Space. Change it under Settings → General.

| Key | Action |
| --- | --- |
| ↑ ↓ (or ⌃P ⌃N) | Move the selection |
| ↵ | Run the first action |
| ⌘↵ | Run the second action |
| ⌘K | Show all actions |
| ⇥ | Jump to a quicklink's arguments |
| ⎋ | Clear, go back, or close |
| ⌘, | Settings |

## Build

Requires macOS 15 or later and Xcode 26 or later.

```sh
make run     # build and launch
make test    # run the core tests
```

Or open `Inky.xcodeproj` in Xcode and run the `Inky` scheme.

## How it is organized

```
Inky/        The app: hotkey, launcher panel, settings. AppKit and SwiftUI.
InkyCore/    Everything without UI: search, ranking, providers, quicklinks.
```

Every feature is a `Provider` (see `InkyCore/Sources/InkyCore/Search/Provider.swift`).
A provider hands the engine results as plain data: a title, an icon description,
actions. The app renders them. Built-in features are written against the same
contract that scripted extensions will use, so the extension API is one that has
already been proven by real features.

Your data lives in `~/Library/Application Support/Inky/` as readable JSON:
`quicklinks.json` and `usage.json`.

### Development flags

Debug builds accept launch arguments that put the app into a known state:

```sh
Inky.app/Contents/MacOS/Inky --pin --query "saf" --keys "cmd+k down"
```

`--show`, `--pin` (stay open without focus), `--quiet` (draw beneath the desktop
and take no focus, for automated captures), `--query <text>`, `--keys "<keys>"`,
`--settings [pane]`, `--new-quicklink`.

## Roadmap

- Lua extensions, hosted behind the `Provider` contract
- Clipboard history
- A persistent index (SQLite) with full-text and, optionally, vector search
- Fallback searches: send the query to a quicklink when nothing else matches
- Signed, notarized releases with automatic updates
