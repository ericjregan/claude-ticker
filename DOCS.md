# Claude Ticker — Reference

Everything beyond installing it: what each row means, where the data comes from, what you
can change, and the platform traps that shaped the implementation.

- [Reading the panel](#reading-the-panel)
- [Design rules](#design-rules)
- [Where the data comes from](#where-the-data-comes-from)
- [Architecture](#architecture)
- [Tuning it](#tuning-it)
- [Troubleshooting](#troubleshooting)
- [Things that are not obvious](#things-that-are-not-obvious)

## Reading the panel

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

Rows sort by priority, then by most recently touched: amber states → the window you are in →
failed → working → everything else.

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
- **`TickerView`** and friends render. Clicks are handled by `MouseView`, an `NSView`
  subclass, not by SwiftUI gestures.

This split matters. An earlier version ran the scan on the main actor, freezing the UI for
roughly half a second every few seconds and making the whole panel feel broken. If you add
work, add it inside `SessionScanner`, never in `Fleet`.

## Tuning it

All in `ClaudeTicker.swift`:

| What | Where | Default |
|---|---|---|
| Poll interval | `Fleet.tickHandler` | 4s active, 10s idle |
| Staleness threshold | `Session.isStale` | 48 hours |
| Context warning color | `RowView.contextColor` | red at 85% |
| Context window sizes | `ContextReader.millionTokenModels` | 1M for Claude 5 family |
| Transcript re-read interval | `ContextReader.minimumRecomputeInterval` | 12s |
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

**Session names look like `myproject-3f`.** That is Claude's throwaway name for an unnamed
session. The panel substitutes the Terminal window's topic when it can find one. Naming
sessions gives the best result.

**Context shows nothing.** The transcript could not be located — most often a session whose
cwd is a git worktree.

## Things that are not obvious

Each of these cost real debugging time and is worth knowing before you modify the source.

**`claude agents --json` only ever reports `busy` or `idle` for interactive sessions.** The
documented `waiting` status and `waitingFor` field effectively never appear, so amber built on
them can only fire for background agents. `your turn` is instead derived from who spoke last
in the transcript — walking the JSONL backwards to the last `user`/`assistant` entry, skipping
metadata records (`bridge-session`, `file-history-snapshot`, `permission-mode`, `pr-link`,
`system`) that otherwise masquerade as the last message.

**A transcript's mtime is not its last activity.** Something touches every `.jsonl`
continuously; files modified "minutes ago" held messages days old. Use the last real message's
timestamp.

**Inside `tell application "Terminal"`, AppleScript's `tab` constant is shadowed** by
Terminal's `tab` class and serializes as the literal text `"tab"`, silently breaking any
`& tab &` delimiter. Use `ASCII character 9`.

**SwiftUI tap gestures never fire in a borderless non-activating panel.** Clicks need an
AppKit view overriding `acceptsFirstMouse`. The same limitation is why resizing uses an
explicit corner grip rather than window edges.

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
