# Claude Ticker — Reference

Everything beyond installing it: what each row means, where the data comes from, what you
can change, and the platform traps that shaped the implementation.

- [Reading the menu bar](#reading-the-menu-bar)
- [Reading the panel](#reading-the-panel)
- [Design rules](#design-rules)
- [Where the data comes from](#where-the-data-comes-from)
- [Architecture](#architecture)
- [Tuning it](#tuning-it)
- [Troubleshooting](#troubleshooting)
- [Things that are not obvious](#things-that-are-not-obvious)

## Reading the menu bar

The item is a double chevron followed by two numbers: **waiting · working**.

| What you see | Means |
|---|---|
| `8·1` (amber 8) | Eight sessions want you, one is still generating. Amber appears only here. |
| `0·2` | Nothing needs you; two sessions are working. |
| `0·0` | A quiet fleet. The width never changes, so the item does not shift under the cursor. |
| `—` | The scan failed. The popover carries the error; a `0·0` here would read as a quiet fleet and lie. |

Click it for the list. Right-click it to show or hide the floating panel, or to quit.

## Reading the panel

The panel is the same list in an always-on-top window, for when you want it permanently in
view. It is hidden until you ask for it, and its ✕ hides it again rather than quitting.

Each row is one session. Left to right: a status rail, the session name, chips, what the
session wants from you, and its context usage.

| What you see | Means |
|---|---|
| `needs you · permission` (amber) | Blocked on a permission prompt. Nothing proceeds until you answer. |
| `waiting for you` (amber) | A background agent finished. Its results are unread. |
| `your turn` (amber) | Claude replied and is waiting on you. |
| `working` (blue, pulsing rail) | Currently generating. |
| `failed` (red) | A background agent errored out. |
| no label | Idle with nothing to report. |
| dimmed name | No real message in 48 hours — effectively abandoned. |
| `here` chip | The Terminal window you are currently focused in. |
| `bg` chip | A background agent rather than a terminal window. |
| `codex` chip | An interactive Codex CLI session. |
| `74%` | Share of the model's context window in use. Red at 85% or above. |
| `✓` | Mark this row read. Only on rows that can be acknowledged. |

Click a row to raise its Terminal window. Drag the header to move the panel, the corner grip
to resize it, and the chevron to collapse it to a header bar.

Rows are grouped by Terminal window, with a hairline between windows, and each window's tabs
appear in the same left-to-right order as its tab bar. A window sits where its most urgent tab
would sort, so anything that wants you still floats to the top: amber states → the window you
are in → failed → working → everything else, then most recently touched.

Grouping needs Accessibility permission (System Settings → Privacy & Security →
Accessibility). Terminal's AppleScript cannot see tab groups, because macOS-native tabs are
separate windows: a window with five tabs scripts as five windows. Only Accessibility exposes
the tab bar. The app asks for the permission at launch. Without it, the list is one flat
priority-ordered list ending in an "Allow Accessibility to group tabs by window" line, which
opens the right settings pane.

## Design rules

These are constraints, not preferences. Breaking them makes the panel less useful in ways
that are not obvious until you live with it.

**Amber means exactly one thing: this session wants you.** Nothing else in the panel may use
it. Urgency is carried by wording, not by additional colors. An earlier version turned the
header amber whenever you were outside Terminal, which diluted the one signal that mattered.

**Green was removed entirely.** A finished background agent originally showed a green "done",
which reads as all-clear when the session actually wants you to read its output. It is amber
now, and ranks above sessions that are still working — a running agent needs nothing from
you; a finished one does.

**Dim means abandoned, never merely idle.** A session you touched an hour ago is live work
whatever its status says. Only a 48-hour silence fades a row. Working or blocked sessions
never dim, which also protects worktree sessions whose transcript cannot be located.

**Nothing happens automatically that was not asked for.** The panel does not resize, hide, or
reorder itself based on which application is frontmost.

**Mark-as-read is an inbox, not a mute.** It records the reply you saw; anything Claude says
afterwards raises the row again. It is deliberately not offered on `needs you`, where hiding
the row would mask genuinely stalled work rather than clear a notification.

## Where the data comes from

Two sources, because one is not enough.

**`claude agents --json`** gives the session list: pid, cwd, kind, name, and a status. This is
where `working`, `needs you`, `waiting for you`, and `failed` come from.

**The session transcript** at `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl` gives what the
CLI does not expose: context usage, true last activity, and whether Claude or you spoke last.
The cwd slug replaces both `/` and `.` with `-`.

Only the tail of each transcript is read (64 KB, widening to 384 KB if that held no usage
block), and only when the file has changed, since these files reach tens of megabytes.

## Architecture

One Swift file, three layers:

- **`SessionScanner`** owns every blocking call — subprocesses and transcript reads — on a
  single serial `DispatchQueue`. That confinement is what makes its `@unchecked Sendable`
  conformance honest.
- **`Fleet`** is the `@MainActor` view model. It schedules scans and publishes results. It
  performs no blocking work.
- **`TickerView`**, **`PopoverView`** and friends render. Clicks are handled by `MouseView`,
  an `NSView` subclass, not by SwiftUI gestures.

This split matters. An earlier version ran the scan on the main actor, freezing the UI for
roughly half a second every few seconds and making the whole panel feel broken. If you add
work, add it inside `SessionScanner`, never in `Fleet`.

Three smaller pieces sit alongside them:

- **`TranscriptWatcher`** holds a `DispatchSource` per live transcript and triggers a scan when
  one is appended to. This is what makes updates immediate; the poll timer is only a backstop
  for sessions appearing and disappearing, which write nothing to an existing transcript.
- **`TranscriptLocator`** answers "where is this session's transcript". The cwd slug is a guess,
  not an answer — see [Things that are not obvious](#things-that-are-not-obvious).
- **`StatusItemController`** owns the menu bar item and its popover. Two containers, one
  `RowView`: the panel and the popover render the same rows.

`PopoverView` and `TickerView` both take their headline numbers from the `summaryLine` /
`waitingCount` / `workingCount` helpers on `[Session]`, so the three surfaces cannot drift.
They hang off the array rather than `Fleet` on purpose: Combine delivers `@Published` values in
`willSet`, so a subscriber reading `fleet.sessions` sees the *previous* list.

## Tuning it

All in `ClaudeTicker.swift`:

| What | Where | Default |
|---|---|---|
| Poll interval (backstop only) | `Fleet.tickHandler` | 4s active, 10s idle |
| Transcript-write debounce | `TranscriptWatcher.init` | 0.35s |
| Minimum gap between scans | `Fleet.transcriptChanged` | 1s |
| Staleness threshold | `Session.isStale` | 48 hours |
| Context warning color | `RowView.contextColor` | red at 85% |
| Context window sizes | `ContextReader.millionTokenModels` | 1M for Claude 5 family |
| Menu bar mark weight | `MissionMark.strokeWidth` | 8 (brand file draws it at 10) |
| Menu bar mark height | `MissionMark.image(height:)` | 13pt |
| Menu bar readout size | `StatusItemController.numberFont` | 12pt |
| Menu bar item width | `defaults write ClaudeTicker statusItemWidth 58` | 52pt (0 = size to content) |
| Popover size | `PopoverMetrics` | 330pt wide, 470pt tall max |
| Colors | `Palette` | — |

Rebuild and restart with `./install.sh`.

## Troubleshooting

**Nothing appears.** Check the log at `ticker.log` in the repo directory. The most common
cause is `claude` not being found: the panel resolves it from `~/.local/bin`, Homebrew, and
`/usr/local/bin`, then falls back to asking a login shell, because GUI processes do not
inherit your shell PATH.

**Clicking a row does nothing.** The row-to-window mapping goes pid → tty → Terminal window
via AppleScript, which needs Automation permission for Terminal (System Settings → Privacy &
Security → Automation). Sessions with no controlling terminal are filtered out precisely
because there is no window to raise.

**The list stopped grouping by window after a rebuild.** An ad-hoc signed binary gets its
Accessibility grant tied to that exact build. A rebuilt one stays listed as allowed but is no
longer trusted, and the list falls back to flat with the "Allow Accessibility" line. Switch
ClaudeTicker off and on again in the Accessibility list.

To stop that happening, create a local signing identity once. `install.sh` signs with it
whenever it exists, and the grant then survives rebuilds:

```sh
printf '%s\n' '[req]' 'distinguished_name = dn' 'x509_extensions = ext' 'prompt = no' \
  '[dn]' 'CN = ClaudeTicker Local Signing' '[ext]' 'basicConstraints = critical,CA:false' \
  'keyUsage = critical,digitalSignature' 'extendedKeyUsage = critical,codeSigning' > /tmp/ct.cnf
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/ct.key -out /tmp/ct.pem -days 3650 -config /tmp/ct.cnf
openssl pkcs12 -export -inkey /tmp/ct.key -in /tmp/ct.pem -name "ClaudeTicker Local Signing" -out /tmp/ct.p12 -passout pass:temp
security import /tmp/ct.p12 -k ~/Library/Keychains/login.keychain-db -P temp -T /usr/bin/codesign
rm /tmp/ct.key /tmp/ct.p12
```

It shows as "not trusted" in `security find-identity`. That's expected for a self-made
certificate and doesn't stop it signing.

**Checking the list without opening it.** `./ClaudeTicker --snapshot out.png` runs one real
scan, prints the rows grouped by window, and renders the drop-down to an image. It shows no
window and leaves the menu bar alone.

**Session names look like `myproject-3f`.** That is Claude's throwaway name for an unnamed
session. The panel substitutes the Terminal window's topic when it can find one. Naming
sessions gives the best result.

**Context shows nothing.** The transcript could not be located. `TranscriptLocator` falls back
to searching every project directory by session id, so this now means the file genuinely is not
there — a session too new to have written one, or one whose transcript was deleted.

**The menu bar item vanished but the app is running.** The panel's ✕ only hides the panel; the
menu bar item is the app. If the item itself is gone, the menu bar is out of room: macOS drops
what does not fit **silently** — no error, no truncation, and accessibility still reports the
item at a correct position and size, so only a screenshot tells you it is not being drawn.
Measured on an eleven-icon bar, 42pt rendered and 46pt did not; installing Docker Desktop was
enough to push the ticker out. Free a slot (System Settings → Control Center, or hide Siri with
`defaults write com.apple.Siri StatusMenuVisible -bool false`), or shrink `statusItemWidth`.

This is why the item is pinned to a constant width instead of sizing to its content: a readout
that grows with the counts would disappear exactly when the counts get interesting.

**The floating panel will not come back.** Right-click the chevron → Show floating panel. Its
visibility persists in `tickerPanelVisible`, and it starts hidden on a fresh install.

## Things that are not obvious

Each of these cost real debugging time and is worth knowing before you modify the source.

**`claude agents --json` only ever reports `busy` or `idle` for interactive sessions.** The
documented `waiting` status and `waitingFor` field effectively never appear, so amber built on
them can only fire for background agents. `your turn` is instead derived from who spoke last
in the transcript — walking the JSONL backwards to the last `user`/`assistant` entry, skipping
metadata records (`bridge-session`, `file-history-snapshot`, `permission-mode`, `pr-link`,
`system`) that otherwise masquerade as the last message.

**A transcript's mtime is not its last activity.** Resuming or reopening a session rewrites the
file, so `.jsonl`s modified "minutes ago" routinely hold messages days old. Use the last real
message's timestamp. Freshness checks key on the file's *size* instead — transcripts are
append-only, so an unchanged byte count proves the newest message is the one already parsed,
and a stat costs microseconds.

That said, transcripts are *quiet*: measured across an eleven-session fleet over ten seconds,
ten of eleven files had identical size and mtime, and only the genuinely active one moved. That
is what makes a `DispatchSource` watcher viable rather than a firehose.

**A session's transcript is not under a slug of the cwd it reports.** It is under the cwd the
session was *started* in. Sessions that moved, or were resumed from elsewhere, keep their
original file — two of eleven live sessions, both git worktrees, resolved by slug alone to
paths that did not exist, and so had never shown a context % or been able to report `your turn`.
`TranscriptLocator` treats the slug as a fast guess and falls back to searching
`~/.claude/projects/*/<sessionId>.jsonl`, caching both hits and misses.

**Inside `tell application "Terminal"`, AppleScript's `tab` constant is shadowed** by
Terminal's `tab` class and serializes as the literal text `"tab"`, silently breaking any
`& tab &` delimiter. Use `ASCII character 9`.

**SwiftUI tap gestures never fire in a borderless non-activating panel.** Clicks need an
AppKit view overriding `acceptsFirstMouse`. The same limitation is why resizing uses an
explicit corner grip rather than window edges.

**`.resizable` gives the panel an OS resize corner even when the grip is hidden.** Collapsing
hides the SwiftUI grip, but macOS still supplies its own — dragging it grew a collapsed panel
into a tall empty box, since the rows, divider, `ctx` column and grip are all gated on
`!collapsed`. A drag past the collapsed height now clears the flag. If a panel is ever blank
below a correct header, suspect view state, not the scanner.

**Never name a colour on the status item's title.** `labelColor` resolves against the *app's*
appearance and renders black while the template image beside it is tinted white by the menu
bar. Leave the foreground attribute unset and macOS draws the text with the same machinery that
tints the image, so the two always agree. Amber is the one deliberate exception: it is a fixed
sRGB value because it carries meaning, not theme.

**A popover from an `.accessory` app must activate.** Without `NSApp.activate`, the popover
never takes key, and a popover that is not key never receives the click meant to dismiss it.

**`System Events … click at {x,y}` is an accessibility press, not a mouse event** — it will not
exercise a real click handler. Test with a synthetic `CGEvent`.

**Headless `claude` runs appear as interactive sessions.** Plugin hooks and scripted
`--output-format stream-json` calls are listed with no status and a fresh throwaway name each
time. They are filtered on whether a tty resolves, which is the same property click-to-focus
depends on.

**Every Claude session also spawns a `codex … mcp-server` helper** holding a tty. The Codex
filter matches the first *non-flag* argument, since `mcp-server` is the last token; otherwise
you get one phantom row per Claude window.

**Context % is the last `message.usage`** (`input + cache_read + cache_creation`).
`message.model` never carries the `[1m]` suffix, so the window size comes from a model-family
table — assuming 200k pins every session at the 99% cap.

## Cost

Roughly 6% of one core and about 47 MB. The floor is `claude agents --json` itself, which
spawns Node and takes ~300 ms per call.
