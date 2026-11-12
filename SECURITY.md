# Security

## Reporting a vulnerability

Please use [GitHub's private vulnerability report form](https://github.com/Hinkolas/inky/security/advisories/new).
Do not post exploit details, clipboard contents, credentials or private file
paths in a public issue. If the private form is unavailable, open an issue
asking for a private reporting channel without including sensitive details.

Include the Inky version or commit, macOS version, reproduction steps using
made-up data, expected and observed behavior, and the potential impact. Reports
are handled on a best-effort basis; there is no guaranteed response time or
bug bounty. Please coordinate disclosure until a fix or mitigation is available.

## Supported versions

During the alpha, security fixes target the latest alpha and `main`.
Older prereleases are not maintained separately. Update to the latest available
version before reporting a problem that may already have been fixed.

## Data and permissions

- Inky is a local, unsandboxed macOS application. It runs with your account's
  permissions; it is not a security boundary against other apps on that account.
- Clipboard history is enabled by default. On first launch it begins keeping
  copies only once the welcome window, which says so and can turn it off, has
  been closed. Copies that password managers mark
  as confidential (`org.nspasteboard.ConcealedType`, 1Password's own marker)
  are left out unless the user turns on keeping them. Other copies, including
  passwords copied from apps that do not mark them, are stored like any copy.
  The history is not encrypted by Inky. Directory permissions
  restrict access to the account, but do not protect against software running
  as that account, administrators, or copies in backups. Disable Clipboard
  History in Settings if that does not suit your use.
- History is in `~/Library/Application Support/Inky/Clipboard/`. Unpinned
  entries expire according to the retention setting; pins remain until removed.
  Deleting an entry is not a guarantee of forensic erasure from journals,
  filesystem snapshots or backups.
- Quicklinks, rankings and command settings are local JSON files in
  `~/Library/Application Support/Inky/`. Preferences use macOS UserDefaults.
- The searches typed into the launcher, with what was typed into the arguments
  of a quicklink, are kept in `history.json` in the same folder, readable by
  the account only and not encrypted. The rankings in `usage.json` also keep
  the last few searches each result was picked for. Settings → General sets
  how many searches are kept, down to none, and clears them: with none, or
  once cleared, neither file keeps what was typed.
- Accessibility access allows selected-text reading and simulated ⌘V. Automation
  access supports commands sent to Finder and other system applications.
- Uninstalling uses name and bundle-identifier heuristics. Review every proposed
  file, especially shared application data. Chosen files go to the Trash;
  Empty Trash is a separate, confirmed, permanent action.

## Network requests

There are no accounts, analytics or telemetry. The built-in background
services can be disabled in Settings:

- Website icons: DuckDuckGo receives quicklink domain names, plus ordinary
  connection metadata such as your IP address. Known local address forms and
  suffixes are excluded, but a private service using a public-looking domain
  cannot reliably be recognized. Disable website icons for sensitive domains.
- Currency rates: the same ECB reference-rate file is fetched for all users;
  the amount and currencies you type are not sent. Cached rates may be old.
- Updates: downloaded builds fetch the update feed from GitHub Pages
  (`getinky.dev/appcast.xml`) about once a day, through Sparkle,
  without its optional system profile. The chosen update channel decides
  whether pre-releases in it are offered; it is not sent anywhere. The feed
  and each update archive must carry EdDSA signatures matching the public key
  built into the app (`SUPublicEDKey`, with `SURequireSignedFeed` and
  `SUVerifyUpdateBeforeExtraction`), and releases are signed with a Developer
  ID and notarized. Debug builds and builds without the key never update.

Opening a quicklink or a clipboard URL uses the selected/default application.
Quicklink placeholders can intentionally put clipboard or selected text into
an outgoing URL. Review a template's destination before using it with secrets.

## If clipboard storage cannot be opened

Inky leaves the existing database, journal files and images in place and uses a
temporary history. New copies in this mode do not survive quitting Inky; the
clipboard screen and settings show a notice.

Try reopening Inky. If the problem continues, quit all copies of Inky and back
up the entire `Clipboard` folder, including `history.sqlite`, any `-wal` and
`-shm` files, and `Images`. Do not remove individual journal files or edit a
live database. Check available disk space and folder permissions. If a newer
Inky version wrote the database, reopen it with that version or a later one.
Ask for help with version details and a description of the failure; do not
attach the database or images to an issue.
