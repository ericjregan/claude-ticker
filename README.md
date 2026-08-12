# Claude Ticker

An always-on-top macOS panel listing every running Claude Code session, so a dozen Terminal
windows stay legible at a glance. Single-file Swift (AppKit + SwiftUI), no dependencies.

Each row is one session: status rail, name, context usage, and what it wants from you.
Click a row to raise its Terminal window. Click the checkmark on an amber row to mark it read.

## Install

Requires macOS and the Xcode Command Line Tools (`xcode-select --install`). No other
dependencies — it compiles with the `swiftc` that ships with them.

```sh
./install.sh
```

That builds the binary, registers a login agent, and starts it. It works from wherever you
cloned or unzipped this; nothing is hardcoded to a particular user or directory. Run it again
after editing the source to rebuild and restart. `./uninstall.sh` removes the agent.

Handing this repo to your own Claude Code session and asking it to install and explain the
panel works too — that is what it was built for.

## Design rules

- **Amber means exactly one thing: this session wants you.** Nothing else uses it. Wording
  carries the urgency instead of extra colors:
  `needs you · permission` (blocked) → `waiting for you` (background agent finished) →
  `your turn` (Claude replied and is waiting).
- **Dim means abandoned** (no real message in 48h), never merely idle. Working or blocked
  sessions never dim.
- **Nothing happens automatically that wasn't asked for.** The panel never resizes or hides
  itself based on which app is frontmost.
- **Mark-as-read is an inbox, not a mute.** It records the reply you saw; anything Claude
  says afterwards raises the row again. Not offered for `needs you`, where hiding the row
  would mask genuinely stalled work.

Rows sort by priority, then by most recently touched: amber states → the window you're in
(`here`) → failed → working → everything else.

## Things that are not obvious

- **`claude agents --json` only ever reports `busy` or `idle` for interactive sessions.** The
  documented `waiting` status and `waitingFor` field effectively never appear, so amber built
  on them can only fire for background agents. "Your turn" is instead derived from who spoke
  last in the session transcript — walking the JSONL backwards to the last `user`/`assistant`
  entry, skipping metadata records (`bridge-session`, `file-history-snapshot`,
  `permission-mode`, `pr-link`, `system`) that otherwise masquerade as the last message.
- **A transcript's mtime is not its last activity.** Something touches every `.jsonl`
  continuously; files modified "minutes ago" held messages days old. Use the last real
  message's timestamp.
- **Inside `tell application "Terminal"`, AppleScript's `tab` constant is shadowed** by
  Terminal's `tab` class and serializes as the literal text `"tab"`, silently breaking any
  `& tab &` delimiter. Use `ASCII character 9`.
- **SwiftUI tap gestures never fire in a borderless non-activating panel.** Clicks need an
  AppKit view overriding `acceptsFirstMouse`. The same limitation is why resizing uses an
  explicit corner grip rather than window edges.
- **`System Events … click at {x,y}` is an accessibility press, not a mouse event** — it will
  not exercise a real click handler. Test with a synthetic `CGEvent`.
- **Every Claude session spawns a `codex … mcp-server` helper** holding a tty. The Codex
  filter matches the first *non-flag* argument, since `mcp-server` is the last token;
  otherwise you get one phantom row per Claude window.
- Context % is the last `message.usage` (`input + cache_read + cache_creation`). `message.model`
  never carries the `[1m]` suffix, so the window size comes from a model-family table —
  assuming 200k pins every session at the 99% cap.

## Cost

Roughly 6% of one core and ~47 MB. The floor is `claude agents --json` itself (~307 ms per
call, spawns Node); the panel polls every 4s while sessions are active, 10s when all idle.
