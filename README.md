# Claude Ticker

A macOS menu bar item listing every running Claude Code session, so a dozen Terminal windows
stay legible at a glance. Single-file Swift (AppKit + SwiftUI), no dependencies.

The menu bar shows two numbers — sessions waiting on you, and sessions still working — behind
a double chevron. The waiting count turns amber when it is above zero, and that is the only
place amber appears. Click for the full list; each row is one session with its status, name,
and how much of its context window is left. Click a row to raise its Terminal window; click
the checkmark to mark it read.

Right-click the chevron to quit, or to summon the original floating panel — an always-on-top
window with the same list, for when you want it permanently in view. It stays hidden until
you ask for it, and its ✕ puts it away again without quitting the menu bar item.

Updates are event-driven: the app watches each session's transcript and refreshes when one is
written to, so "your turn" appears as the reply lands rather than on the next poll.

## How It All Connects

```
   claude agents --json                    session transcripts (.jsonl)
   roster · status · cwd                   context % · who spoke last
              │                                        │
              └────────────────────┬───────────────────┘
                                   ▼
                           SessionScanner
              every blocking call, on one serial queue
                                   │
                                   ▼
                                 Fleet
                  @MainActor · publishes · never blocks
                                   │
                 ┌─────────────────┴─────────────────┐
                 ▼                                   ▼
          Menu bar item                       Floating panel
          ⌃⌃  8 · 1  + popover                always-on-top list

                           TranscriptWatcher
              DispatchSource on each live transcript —
              a reply lands, the row changes, no polling
```

| Piece | What it does |
|-------|--------------|
| **Menu bar item** | Two numbers behind a double chevron — waiting, then working. Amber appears here and nowhere else. |
| **Popover** | The full list. One row per session: status, name, context remaining. |
| **Floating panel** | The same list in an always-on-top window, summoned when you want it permanently in view. |
| **Transcript watcher** | Refreshes the moment a reply lands, rather than on the next poll. |

## What a row tells you

| You see | It means |
|---------|----------|
| `needs you · permission` | Blocked on a permission prompt. Nothing proceeds until you answer. |
| `waiting for you` | A background agent finished. Its results are unread. |
| `your turn` | Claude replied and is waiting on you. |
| `working` | Currently generating. |
| dimmed name | No real message in 48 hours — effectively abandoned. |
| `74%` | Share of the context window in use. Red at 85%. |

Amber means exactly one thing: that session wants you.

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

## Documentation

**[Read the docs →](DOCS.md)** — what each row means, where the data comes from, the design
rules worth preserving, how to tune the thresholds, and the platform traps that shaped the
implementation.

Worth knowing up front: `claude agents --json` only ever reports `busy` or `idle` for terminal
sessions, so "waiting on you" cannot come from the CLI. It is derived from who spoke last in
each session's transcript. The docs explain that and the rest.

## License

MIT — see [LICENSE](LICENSE).
