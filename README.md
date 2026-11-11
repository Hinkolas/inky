# Inky

A fast, open source launcher for macOS. Press a hotkey anywhere, type, and act:
launch apps, open links with arguments, calculate and convert, ask for the
time somewhere, look at a color, find files, run system commands. No accounts, no subscriptions, no telemetry.

Inky is at an early stage. The core works and is meant to be built on.

## What it does today

- **Applications**: fuzzy search over installed apps, ranked by how often and how recently you pick them. What you pick for a search rises to the top; Reset Ranking under ⌘K makes a result forget that.
- **Uninstall Application**: removes an app together with what it left in your Library: settings, caches, saved state. Pick the app from the command's list, or press ⌃X on it in the results. Inky lists what it found, each file with a box to keep it, and ⌘↵ moves the rest to the Trash, where everything can be put back. A file counts as the app's if it is named after the app's bundle identifier, or after the app itself; what another installed app calls its own is never listed, and neither are the apps macOS is made of.
- **Quicklinks**: named shortcuts to websites, folders and app links. Placeholders such as `{argument name="Query"}`, `{clipboard}` and `{selection}` are filled in when the link opens; arguments are typed right in the search bar. Websites show their own icon. Edit (⌘E) or delete (⌃X) one right from the results.
- **Clipboard History**: keeps what you copy, be it text, links, colors, images or files, to find it and paste it again. Return pastes an item into the app you were in; ⌘C only copies it, ⌥↵ pastes text without its formatting. Type to find words anywhere in what was copied, press ⇥ to go through the kinds, and narrow it down to what was copied lately. Pin (⌘P) what you need again and again: pinned items stay for good, sit in the sidebar, are reached with ↑ from the latest copy, and can be given a name (⌘R) to find them by. Settings → Clipboard History says how long a copy is kept, from a day to forever, and what Return does. Like any command, the history can have a hotkey of its own.
- **Commands and hotkeys**: everything Inky lists is a command, be it an application, a quicklink or a system command. Each can be switched off, so that what you never open is not found or suggested, and each can have a hotkey that runs it from anywhere: launch an app, lock the screen, open a folder. A command that opens in Inky, such as the clipboard history, shows Inky with it, and puts it away when pressed again; a quicklink that asks for arguments shows Inky to take them. Settings → Commands lists them all in one place, and the pane of each module lists its own. In the results, Disable Command under ⌘K (⌃⇧⌘D) switches off the selected one, and Configure Command… shows it in the settings.
- **Fallback commands**: every search can be sent on to a command that takes one argument, such as a quicklink for a web search. They are listed below the results, and are all there is when nothing was found. Choose them, and their order, under Settings → Fallback Commands.
- **Calculator**: type `128 * 3 + 4`, `20% off 80` or `sqrt(2) ^ 10`, press Return to copy the result. It converts units (`5 ft 10 in in cm`, `72 F to C`, `1 GiB in MB`), currencies (`100 usd in eur`), number bases (`255 in hex`, `0xFF`) and the units of a web page (`2rem in px`, with the size of a rem set in Settings).
- **Time**: `time in tokyo`, `5pm london in berlin`, `time diff san francisco`, `monday in 3 weeks`, `days until 24 dec`.
- **Color**: type a color the way a stylesheet writes it, such as `#ff6363`, `rgb(255 99 99 / 50%)` or `oklch(0.7 0.19 23)`, to see it and copy it written another way. `#fa32fa in rgb` asks for one; ⌘K lists them all, from hex and HSL to OKLCH and a color in Swift. The one you copy most comes first.
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

The clipboard history stays on your Mac, in a database only your account can
read, and is never sent anywhere. Passwords copied from a password manager are
kept like anything else for now. What an app puts on the clipboard only to
move it along, as text expanders do, is left out.

Two things in it need your say. macOS asks before an app may read what other
apps copied: the first time Inky does, allow it, and choose Allow for Inky
under System Settings → Privacy & Security → Paste from Other Apps, or macOS
would ask again with every copy and Inky keeps nothing. And to paste for you,
Inky presses ⌘V, which takes Accessibility access; until it has that, it
copies and you paste.

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
| ⌃⇧⌘D | Disable the selected command |
| ⎋ | Clear, go back, or close |
| ⌘, | Settings |

## Build

Requires macOS 15 or later and Xcode 26 or later.

```sh
make run     # build and launch
make test    # run the core tests
make places  # rebuild the list of cities from GeoNames
```

Or open `Inky.xcodeproj` in Xcode and run the `Inky` scheme.

## How it is organized

```
Inky/        The app: hotkey, launcher panel, settings. AppKit and SwiftUI.
InkyCore/    Everything without UI: search, ranking, modules, quicklinks.
```

Every feature is a module (see `InkyCore/Sources/InkyCore/Search/Module.swift`).
The ones that come with Inky, such as the calculator and quicklinks, are system
modules; an extension is a module that does not come with Inky. A module hands
the engine results as plain data: a title, an icon description, actions. The app
renders them. System modules are written against the same contract that scripted
extensions will use, so the extension API is one that has already been proven by
real features.

A command's screen is put together from a small set of parts in
`Inky/Commands/CommandKit.swift`: `CommandScreen` (the header pill a command
configures and the body card, which the launcher's own bar and card turn
into), `Sidebar` for narrowing down
what is shown, `SidePanel` for previews, details and actions, and the rows,
form groups and controls that go inside them. The quicklink browser and editor
are built from these, and extensions will describe the same parts as data.

Your data lives in `~/Library/Application Support/Inky/` as readable JSON:
`quicklinks.json`, `usage.json`, `fallbacks.json` and `commands.json`, which
names the commands you switched off and the hotkeys you gave.

The clipboard history is the exception: `Clipboard/history.sqlite`, with the
images as files next to it. It can grow to many thousands of entries, so it
is read a page at a time and searched through an index of every run of three
characters (SQLite's FTS5), which finds words anywhere in a text without
reading the texts. macOS does not say when something is copied; Inky looks at
the pasteboard's change count twice a second and reads it only when that moved
(`InkyCore/Sources/InkyCore/Clipboard/`).

The calculator and the time module share a lexer and the table of units
(`InkyCore/Sources/InkyCore/Calculator/`). Each has a recursive descent parser
of its own on top: a calculation becomes a number or an amount with a unit, a
question about time becomes a moment or a day. Neither answers a word or a
number on its own, so a search stays a search.

The cities the time module knows, in
`InkyCore/Sources/InkyCore/Resources/places.tsv`, are from
[GeoNames](https://www.geonames.org), licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

### Development flags

Debug builds accept launch arguments that put the app into a known state:

```sh
Inky.app/Contents/MacOS/Inky --pin --query "saf" --keys "cmd+k down"
```

`--show`, `--pin` (stay open without focus), `--quiet` (draw beneath the desktop,
take no focus and register no hotkey or menu bar icon, for automated captures),
`--query <text>`, `--keys "<keys>"` (among them `run:<command id>`, which does
what the command's hotkey does), `--settings [pane]`, `--search <text>` (what
the settings' list of all commands is narrowed down to), `--quicklinks`,
`--new-quicklink`, `--uninstall [application]`, `--clipboard [filter]`,
`--clipboard-samples` (fill an empty history with made-up copies, with `--data`
only), `--appearance light|dark`, `--backdrop light|dark` (a
stand-in wallpaper behind a quiet launcher, to see the translucency),
`--data <folder>` (keep quicklinks, usage and the clipboard history there
instead of in your own, with a pasteboard to itself and without pressing keys
in other apps, and uninstall only the applications in its `Applications`, with
what they left in its `Library`),
`--motion full|reduced|off`, and `--slow <factor>` (stretch every animation, to
look at one frame by frame).

## Roadmap

- Lua extensions, hosted behind the `Module` contract
- Passwords in the clipboard history: left out, or kept locked
- A calendar that knows your working days and holidays, to answer `workdays in march` and `55h in workdays`
- Sizes for print and export in the calculator: `2 inches in px at 72 ppi`
- Airports in the time module: `time in JFK`
- A persistent index (SQLite) with full-text and, optionally, vector search
- Signed, notarized releases with automatic updates
