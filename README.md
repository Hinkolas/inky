# Inky

A fast, open source launcher for macOS. Press a hotkey anywhere, type, and act:
launch apps, open links with arguments, calculate and convert, find files, run
system commands. No accounts, no subscriptions, no telemetry.

Inky is at an early stage. The core works and is meant to be built on.

## What it does today

- **Applications**: fuzzy search over installed apps, ranked by how often and how recently you pick them.
- **Quicklinks**: named shortcuts to websites, folders and app links. Placeholders such as `{argument name="Query"}`, `{clipboard}` and `{selection}` are filled in when the link opens; arguments are typed right in the search bar. Websites show their own icon.
- **Fallback commands**: every search can be sent on to a quicklink, such as a web search. They are listed below the results, and are all there is when nothing was found. Pick which quicklinks in Settings.
- **Calculator**: type `128 * 3 + 4`, `20% off 80` or `sqrt(2) ^ 10`, press Return to copy the result. It converts units (`5 ft 10 in in cm`, `72 F to C`, `1 GiB in MB`), currencies (`100 usd in eur`) and number bases (`255 in hex`, `0xFF`).
- **File search**: files and folders by name, from the Spotlight index.
- **System commands**: lock, sleep, restart, shut down, log out, empty trash, toggle dark mode.

The default hotkey is ⌥Space. Change it under Settings → General, where you
also choose a light or dark appearance, or leave that to the system, and turn
the launcher's animations off. With Reduce Motion on in System Settings the
launcher fades instead of moving.

Inky fetches two things from the internet, and either can be turned off.

Website icons: it asks DuckDuckGo for the icon of each website in your
quicklinks, sending only the domain name, and keeps the answer on your Mac for
30 days. Local addresses such as `localhost` are never sent. Settings →
General turns this off, and fetches all icons again when you ask.

Exchange rates: it downloads the reference rates of the European Central Bank,
one file with about thirty currencies, a few times a day while you use the
calculator. The file is the same for everyone, so nothing about what you
convert is sent. Settings → Calculator turns this off, and currencies are then
not converted.

Inky opens as a single floating bar. Results appear in a card below it as you
type. A command that needs more room, such as Manage Quicklinks, takes over
with a screen of its own: a back button and a header above a card.

| Key | Action |
| --- | --- |
| ↓ | With nothing typed: show suggestions |
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

A command's screen is put together from a small set of parts in
`Inky/Commands/CommandKit.swift`: `CommandScreen` (the header pill a command
configures and the body card, which the launcher's own bar and card turn
into), `Sidebar` for narrowing down
what is shown, `SidePanel` for previews, details and actions, and the rows,
form groups and controls that go inside them. The quicklink browser and editor
are built from these, and extensions will describe the same parts as data.

Your data lives in `~/Library/Application Support/Inky/` as readable JSON:
`quicklinks.json` and `usage.json`.

The calculator (`InkyCore/Sources/InkyCore/Calculator/`) is a lexer, a
recursive descent parser and a table of units. A calculation becomes a number
or an amount with a unit. A word or a number on its own is not answered, so a
search stays a search.

### Development flags

Debug builds accept launch arguments that put the app into a known state:

```sh
Inky.app/Contents/MacOS/Inky --pin --query "saf" --keys "cmd+k down"
```

`--show`, `--pin` (stay open without focus), `--quiet` (draw beneath the desktop,
take no focus and register no hotkey or menu bar icon, for automated captures),
`--query <text>`, `--keys "<keys>"`, `--settings [pane]`, `--quicklinks`,
`--new-quicklink`, `--appearance light|dark`, `--backdrop light|dark` (a
stand-in wallpaper behind a quiet launcher, to see the translucency),
`--data <folder>` (keep quicklinks and usage there instead of in your own),
`--motion full|reduced|off`, and `--slow <factor>` (stretch every animation, to
look at one frame by frame).

## Roadmap

- Lua extensions, hosted behind the `Provider` contract
- Clipboard history
- A persistent index (SQLite) with full-text and, optionally, vector search
- Signed, notarized releases with automatic updates
