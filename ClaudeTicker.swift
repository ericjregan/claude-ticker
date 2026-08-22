import AppKit
import SwiftUI

// MARK: - Model

/// Ordering is the priority ladder. A finished background agent outranks a running one:
/// it has work sitting there waiting to be read, which is why it's amber and not green —
/// "done" read as all-clear when the session actually wanted attention.
enum SessionState: Int, Comparable {
    case needsYou = 0     // blocked on a permission prompt
    case done     = 1     // background agent finished, results unread
    case failed   = 2
    case yourTurn = 3     // Claude answered and is waiting on your reply
    case working  = 4
    case idle     = 5

    static func < (a: SessionState, b: SessionState) -> Bool { a.rawValue < b.rawValue }

    /// Every amber state means the same thing — this session wants you. The wording
    /// distinguishes how urgently.
    var wantsYou: Bool { self == .needsYou || self == .done || self == .yourTurn }

    /// A finished agent or an unanswered reply can be acknowledged. A session blocked on a
    /// live permission prompt cannot — dismissing it would hide work that is genuinely stuck.
    var dismissible: Bool { self == .done || self == .yourTurn }

    var label: String {
        switch self {
        case .needsYou: return "needs you"
        case .done:     return "waiting for you"
        case .failed:   return "failed"
        case .yourTurn: return "your turn"
        case .working:  return "working"
        case .idle:     return ""
        }
    }

    var color: Color {
        switch self {
        case .needsYou, .done, .yourTurn: return Palette.amber
        case .failed:                     return Palette.red
        case .working:                    return Palette.blue
        case .idle:                       return Palette.faint
        }
    }
}

struct Session: Identifiable {
    let id: String
    let name: String
    let pid: Int?
    let cwd: String
    let tag: String?              // "bg" | "codex"
    let state: SessionState
    let detail: String?           // e.g. "permission", "input"
    let startedAt: Double         // epoch ms; newest sorts first
    var labelOverride: String?    // Codex status is CPU-inferred, so it says "active", not "working"
    var isFocused: Bool = false   // the Terminal window you're currently in
    var contextPercent: Int?      // share of the model's context window in use
    var lastActivity: Double?     // epoch seconds; drives the stale (dimmed) treatment

    /// Only genuinely abandoned sessions fade out. Idle-but-recent stays fully legible —
    /// a session you touched an hour ago is still live work, whatever its status says.
    /// Anything currently running or blocked on you is never abandoned by definition,
    /// which also protects worktree sessions whose transcript can't be located.
    var isStale: Bool {
        guard state == .idle, let t = lastActivity else { return false }
        return Date().timeIntervalSince1970 - t > 48 * 3600
    }
}

/// Raw shape of `claude agents --json`.
private struct RawSession: Decodable {
    let pid: Int?
    let id: String?
    let cwd: String?
    let kind: String?
    let sessionId: String?
    let name: String?
    let status: String?      // interactive: idle | busy | waiting
    let state: String?       // background: working | blocked | done | failed | stopped
    let waitingFor: String?
    let startedAt: Double?
}

// MARK: - Palette
// Amber is load-bearing: it means "act now" and appears nowhere else.

enum Palette {
    static let ink   = Color(red: 0.910, green: 0.902, blue: 0.882)
    static let dim   = Color(red: 0.541, green: 0.529, blue: 0.506)
    static let faint = Color(red: 0.333, green: 0.325, blue: 0.310)
    static let amber = Color(red: 1.000, green: 0.690, blue: 0.125)
    static let blue  = Color(red: 0.298, green: 0.620, blue: 0.910)
    static let green = Color(red: 0.357, green: 0.788, blue: 0.549)
    static let red   = Color(red: 0.910, green: 0.337, blue: 0.298)
}

// MARK: - Context usage
//
// `claude agents --json` doesn't report context use, but each session's transcript does:
// the last assistant message's usage block is the live context total. Files reach tens of
// MB, so only the tail is read, and only when the file has actually changed.

final class ContextReader {
    struct Info {
        var percent: Int?
        var lastMessageAt: Double?
        /// "assistant" means Claude spoke last and the session is waiting on a reply.
        var lastRole: String?
    }

    private struct Entry {
        let size: UInt64
        let mtime: Double
        let info: Info
        let computedAt: Double
    }

    private let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain = ISO8601DateFormatter()

    private func parseISO(_ s: String) -> Double? {
        isoFractional.date(from: s)?.timeIntervalSince1970
            ?? isoPlain.date(from: s)?.timeIntervalSince1970
    }

    private var cache: [String: Entry] = [:]

    /// Context share drifts slowly, so a busy session doesn't need it recomputed every poll —
    /// re-reading multi-MB transcripts that often is the single most expensive thing here.
    private let minimumRecomputeInterval: Double = 12

    func info(sessionId: String, cwd: String) -> Info {
        let now = Date().timeIntervalSince1970
        if let hit = cache[sessionId], now - hit.computedAt < minimumRecomputeInterval {
            return hit.info
        }
        guard let url = transcriptURL(sessionId: sessionId, cwd: cwd) else { return Info() }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return Info() }

        if let hit = cache[sessionId], hit.size == size, hit.mtime == mtime {
            cache[sessionId] = Entry(size: size, mtime: mtime, info: hit.info, computedAt: now)
            return hit.info
        }

        let scan = scanTranscript(url: url, size: size)
        cache[sessionId] = Entry(size: size, mtime: mtime, info: scan, computedAt: now)
        return scan
    }

    /// Claude stores transcripts under a slug of the cwd: "/" and "." both become "-".
    private func transcriptURL(sessionId: String, cwd: String) -> URL? {
        guard !cwd.isEmpty else { return nil }
        let slug = cwd.replacingOccurrences(of: "/", with: "-")
                      .replacingOccurrences(of: ".", with: "-")
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects/\(slug)/\(sessionId).jsonl")
    }

    /// Transcripts record `message.model` without the `[1m]` suffix, so the window size has
    /// to come from the model family. Observed usage is the tiebreaker: a session sitting at
    /// 881k tokens is proof of a 1M window no matter what the id says.
    private static let millionTokenModels = [
        "claude-fable-5", "claude-mythos-5", "claude-opus-5", "claude-opus-4-8", "claude-sonnet-5"
    ]

    private static func contextLimit(model: String, used: Int) -> Int {
        if model.contains("[1m]") || millionTokenModels.contains(where: { model.hasPrefix($0) }) {
            return 1_000_000
        }
        return used > 200_000 ? 1_000_000 : 200_000
    }

    private func scanTranscript(url: URL, size: UInt64) -> Info {
        // Try a small tail first; only widen if it held no usage block.
        var best = Info()
        for window: UInt64 in [64 * 1024, 384 * 1024] {
            let scan = scanTail(url: url, size: size, window: window)
            best = Info(percent: scan.percent ?? best.percent,
                        lastMessageAt: scan.lastMessageAt ?? best.lastMessageAt,
                        lastRole: scan.lastRole ?? best.lastRole)
            if best.percent != nil || size <= window { break }
        }
        return best
    }

    private func scanTail(url: URL, size: UInt64, window: UInt64) -> Info {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Info() }
        defer { try? handle.close() }

        let start = size > window ? size - window : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return Info() }

        var out = Info()

        // Walk backwards for the newest usage block and the newest real message. Transcripts
        // are full of metadata records (bridge-session, file-history-snapshot, permission-mode)
        // whose timestamps say nothing about the conversation — only user/assistant entries count.
        for line in text.split(separator: "\n").reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            let type = obj["type"] as? String
            if out.lastRole == nil, type == "assistant" || type == "user", obj["message"] != nil {
                out.lastRole = type
                if let stamp = obj["timestamp"] as? String { out.lastMessageAt = parseISO(stamp) }
            }

            if out.percent == nil,
               let message = obj["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                let fields = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                let used = fields.reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
                if used > 0 {
                    let model = (message["model"] as? String) ?? ""
                    let limit = Self.contextLimit(model: model, used: used)
                    out.percent = min(99, Int((Double(used) / Double(limit) * 100).rounded()))
                }
            }

            if out.percent != nil, out.lastRole != nil { break }
        }
        return out
    }
}

// MARK: - Scanning
//
// Every blocking call lives here: `claude agents --json` alone costs ~300ms, plus osascript,
// ps, and transcript reads. Run on the main thread that froze the UI for roughly half a
// second at a time, which is what made the panel feel unlike a native window. All of it now
// runs on one serial queue — that confinement is what makes @unchecked Sendable honest.

final class SessionScanner: @unchecked Sendable {
    struct Result: Sendable {
        let sessions: [Session]
        let error: String?
    }

    private let queue = DispatchQueue(label: "com.claude-ticker.scan", qos: .userInitiated)
    private let context = ContextReader()
    private var claudePath: String?
    private var resolvedClaude = false
    private var ttyCache: [Int: String] = [:]
    private var titleByTTY: [String: String] = [:]
    private var focusedTTY: String?
    private var sinceTerminalPoll = 99
    private var dismissed: [String: Double]

    init() {
        dismissed = (UserDefaults.standard.dictionary(forKey: "tickerDismissed") as? [String: Double]) ?? [:]
    }

    func scan(completion: @escaping @Sendable (Result) -> Void) {
        queue.async {
            let result = self.performScan()
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Records the reply that was seen; anything newer raises the row again.
    func markRead(id: String, lastActivity: Double?, completion: @escaping @Sendable (Result) -> Void) {
        queue.async {
            self.dismissed[id] = max(lastActivity ?? 0, Date().timeIntervalSince1970)
            UserDefaults.standard.set(self.dismissed, forKey: "tickerDismissed")
            let result = self.performScan()
            DispatchQueue.main.async { completion(result) }
        }
    }

    func focus(pid: Int) {
        queue.async {
            guard let dev = self.tty(for: pid) else { return }
            let script = """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  try
                    if tty of t is "\(dev)" then
                      set selected of t to true
                      set frontmost of w to true
                      activate
                      return
                    end if
                  end try
                end repeat
              end repeat
            end tell
            """
            Self.run("/usr/bin/osascript", ["-e", script])
        }
    }

    // MARK: The scan itself

    private func performScan() -> Result {
        if !resolvedClaude {
            claudePath = Self.resolveClaude()
            resolvedClaude = true
        }
        guard let claude = claudePath else {
            return Result(sessions: [], error: "claude not found on PATH")
        }

        sinceTerminalPoll += 1
        if sinceTerminalPoll >= 2 {
            sinceTerminalPoll = 0
            refreshTerminalState()
        }

        guard let out = Self.run(claude, ["agents", "--json"]),
              let data = out.data(using: .utf8),
              let raw = try? JSONDecoder().decode([RawSession].self, from: data) else {
            return Result(sessions: [], error: "couldn't read sessions")
        }

        let mapped: [Session] = raw.compactMap { r -> Session? in
            let isBg = (r.kind == "background")

            // Headless `claude` runs — plugin hooks spawning a reviewer, scripted
            // `--output-format stream-json` calls — are listed as interactive sessions but
            // own no terminal. They appear and vanish with a fresh throwaway name each time,
            // and there is no window to click through to. A real window always has a tty.
            if !isBg, r.pid.flatMap({ tty(for: $0) }) == nil { return nil }
            let sid0 = r.sessionId ?? r.id ?? ""
            let probe = sid0.isEmpty ? ContextReader.Info()
                                     : context.info(sessionId: sid0, cwd: r.cwd ?? "")
            let idleAge = Date().timeIntervalSince1970 - (probe.lastMessageAt ?? 0)

            var state: SessionState
            var detail: String? = nil

            if r.status == "waiting" || r.state == "blocked" {
                state = .needsYou
                detail = r.waitingFor.map(Self.shortenWaiting)
            } else if r.state == "failed" {
                state = .failed
            } else if r.state == "done" {
                state = .done
            } else if r.status == "busy" || r.state == "working" {
                state = .working
            } else if !isBg, probe.lastRole == "assistant",
                      probe.lastMessageAt != nil, idleAge < 48 * 3600 {
                // The CLI reports plain "idle" whether Claude just finished answering or the
                // window was abandoned last week. Claude having spoken last is what separates
                // "your turn" from "nothing here".
                state = .yourTurn
            } else {
                state = .idle
            }

            // Marked read stays quiet until Claude says something new.
            if state.dismissible, let seen = dismissed[sid0], (probe.lastMessageAt ?? 0) <= seen {
                state = .idle
            }

            // Unnamed sessions get a throwaway auto-name ("myproject-3f"); the
            // Terminal window title holds the real topic, so prefer that.
            var displayName = r.name ?? "untitled"
            if Self.isAutoName(displayName, cwd: r.cwd ?? ""),
               let pid = r.pid, let dev = tty(for: pid),
               let topic = titleByTTY[dev] {
                displayName = topic
            }

            let sid = sid0.isEmpty ? UUID().uuidString : sid0
            // A session resumed from an old transcript can have messages older than its own
            // start, so take whichever is more recent as the true "last touched".
            let touched = max(probe.lastMessageAt ?? 0, (r.startedAt ?? 0) / 1000)

            return Session(
                id: sid,
                name: displayName,
                pid: r.pid,
                cwd: r.cwd ?? "",
                tag: isBg ? "bg" : nil,
                state: state,
                detail: detail,
                startedAt: r.startedAt ?? 0,
                contextPercent: probe.percent,
                lastActivity: touched > 0 ? touched : nil
            )
        }

        var all = mapped + scanCodex()
        if let front = focusedTTY {
            all = all.map { s in
                var copy = s
                copy.isFocused = s.pid.flatMap { self.tty(for: $0) } == front
                return copy
            }
        }
        all.sort {
            let a = Self.rank($0), b = Self.rank($1)
            if a != b { return a < b }
            return ($0.lastActivity ?? $0.startedAt / 1000) > ($1.lastActivity ?? $1.startedAt / 1000)
        }
        return Result(sessions: all, error: nil)
    }

    /// Priority ladder. Amber stays above the focused window on purpose: a blocked session
    /// is an interrupt you haven't cleared, and you can already see the window you're in.
    /// Everything below that is ordered by how recently it was touched.
    private static func rank(_ s: Session) -> Int {
        if s.state.wantsYou  { return 0 }
        if s.isFocused       { return 1 }
        if s.state == .failed  { return 2 }
        if s.state == .working { return 3 }
        return 4
    }

    // MARK: Helpers

    /// GUI processes don't inherit a login PATH, so ask a login shell where claude lives.
    private static func resolveClaude() -> String? {
        for candidate in ["\(NSHomeDirectory())/.local/bin/claude",
                          "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude"] where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let found = run("/bin/zsh", ["-lc", "command -v claude"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (found?.isEmpty == false) ? found : nil
    }

    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Codex has no `agents --json` equivalent, so interactive CLI sessions are found by
    /// process + tty. Subcommand processes (mcp-server, sandbox, exec…) are helpers, not
    /// sessions — every Claude window spawns one, so failing to exclude them floods the list.
    private static let codexHelperSubcommands: Set<String> = [
        "mcp-server", "mcp", "app-server", "sandbox", "exec", "login", "logout",
        "completion", "apply", "--version", "--help", "-V", "-h"
    ]

    private func scanCodex() -> [Session] {
        guard let out = Self.run("/bin/ps", ["-eo", "pid=,tty=,pcpu=,args="]) else { return [] }

        return out.split(separator: "\n").compactMap { line -> Session? in
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 4,
                  let pid = Int(f[0]),
                  let cpu = Double(f[2]),
                  f[1] != "??",                                    // no controlling terminal = not a window
                  (f[3] as NSString).lastPathComponent == "codex"
            else { return nil }

            // The subcommand is the first non-flag argument, not necessarily the first —
            // `codex --dangerously-bypass-approvals-and-sandbox mcp-server` puts it last.
            let subcommand = f.dropFirst(4).first { !$0.hasPrefix("-") } ?? ""
            guard !Self.codexHelperSubcommands.contains(subcommand) else { return nil }

            let dev = "/dev/" + f[1]
            let name = titleByTTY[dev] ?? "codex · \(f[1].replacingOccurrences(of: "ttys", with: "s"))"

            // CPU is a heuristic, not a reported state — so it only ever claims "active",
            // and stays silent rather than asserting "idle" it can't actually verify.
            let busy = cpu > 15.0
            return Session(
                id: "codex-\(pid)",
                name: name,
                pid: pid,
                cwd: "",
                tag: "codex",
                state: busy ? .working : .idle,
                detail: nil,
                startedAt: 0,
                labelOverride: busy ? "active" : nil
            )
        }
    }

    /// True for throwaway names Claude generates for unnamed sessions: "<cwd-basename>-<2 hex>".
    static func isAutoName(_ name: String, cwd: String) -> Bool {
        let base = (cwd as NSString).lastPathComponent
        guard !base.isEmpty, name.hasPrefix(base + "-") else { return false }
        let suffix = name.dropFirst(base.count + 1)
        return suffix.count == 2 && suffix.allSatisfy(\.isHexDigit)
    }

    /// One AppleScript round-trip for both the window titles and which window is frontmost.
    /// NOTE: the delimiter is `ASCII character 9`, never the `tab` constant — inside a
    /// `tell application "Terminal"` block `tab` resolves to Terminal's tab *class* and
    /// silently serializes as the literal text "tab".
    private func refreshTerminalState() {
        let script = """
        set d to ASCII character 9
        tell application "Terminal"
          set out to ""
          try
            set out to "FRONT" & d & (tty of tab 1 of front window) & linefeed
          end try
          repeat with w in windows
            try
              repeat with t in tabs of w
                try
                  set out to out & (tty of t) & d & (name of w) & linefeed
                end try
              end repeat
            end try
          end repeat
          return out
        end tell
        """
        guard let out = Self.run("/usr/bin/osascript", ["-e", script]) else { return }
        var map: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }
            if parts[0] == "FRONT" {
                focusedTTY = parts[1]
            } else if let topic = Self.topic(fromWindowTitle: parts[1]) {
                map[parts[0]] = topic
            }
        }
        titleByTTY = map
    }

    /// "myproject — ⠂ Fix the login redirect — caffeinate ◂ claude — 97×23" -> "Fix the login redirect"
    static func topic(fromWindowTitle title: String) -> String? {
        let parts = title.components(separatedBy: " — ")
        guard parts.count >= 3 else { return nil }
        var t = parts[1].trimmingCharacters(in: .whitespaces)
        // Strip whatever spinner glyph Claude is animating in the title — it cycles through
        // braille (⠐) and asterisk (✳) forms, so drop any leading non-alphanumeric decoration.
        while let f = t.first, !f.isLetter, !f.isNumber {
            t.removeFirst()
            t = t.trimmingCharacters(in: .whitespaces)
        }
        let processNames = ["claude", "codex", "caffeinate", "-zsh", "zsh", "bash", "node", "ssh"]
        if processNames.contains(where: { t == $0 || t.hasPrefix($0 + " ") }) { return nil }
        return t.isEmpty ? nil : t
    }

    private static func shortenWaiting(_ s: String) -> String {
        let t = s.lowercased()
        if t.contains("permission") { return "permission" }
        if t.contains("input")      { return "input" }
        if t.contains("sandbox")    { return "sandbox" }
        if t.contains("dialog")     { return "dialog" }
        return t
    }

    private func tty(for pid: Int) -> String? {
        if let cached = ttyCache[pid] { return cached }
        guard let out = Self.run("/bin/ps", ["-o", "tty=", "-p", String(pid)])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !out.isEmpty, out != "??" else { return nil }
        let dev = "/dev/" + out
        ttyCache[pid] = dev
        return dev
    }
}

// MARK: - Fleet
//
// Main-actor view model. It owns no blocking work — it schedules scans and publishes results.

@MainActor
final class Fleet: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var lastError: String?

    private let scanner = SessionScanner()
    private var timer: Timer?
    private var scanning = false
    private var sinceSessionPoll = 99

    func start() {
        tickHandler()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickHandler() }
        }
    }

    /// `claude agents --json` costs ~300ms per call, so poll fast only when something is
    /// moving and back off when the whole fleet is parked.
    private func tickHandler() {
        sinceSessionPoll += 1
        let anythingHappening = sessions.contains { $0.state == .needsYou || $0.state == .working }
        guard sinceSessionPoll >= (anythingHappening ? 4 : 10), !scanning else { return }
        sinceSessionPoll = 0
        scanning = true
        scanner.scan { [weak self] result in
            Task { @MainActor in self?.apply(result) }
        }
    }

    func focus(_ session: Session) {
        guard let pid = session.pid else { return }
        scanner.focus(pid: pid)
    }

    func markRead(_ session: Session) {
        scanner.markRead(id: session.id, lastActivity: session.lastActivity) { [weak self] result in
            Task { @MainActor in self?.apply(result) }
        }
    }

    private func apply(_ result: SessionScanner.Result) {
        scanning = false
        lastError = result.error
        if result.error == nil || !result.sessions.isEmpty { sessions = result.sessions }
    }
}

// MARK: - Views

/// SwiftUI tap gestures never fire in a non-activating panel that isn't key, so clicks are
/// handled at the AppKit layer instead. `acceptsFirstMouse` is the piece that matters: it
/// delivers the click on the very first press, without first stealing focus from a terminal.
final class MouseView: NSView {
    var onClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
    override func mouseUp(with event: NSEvent) { onClick() }
}

struct MouseArea: NSViewRepresentable {
    let onClick: () -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> MouseView {
        let v = MouseView()
        v.onClick = onClick
        v.onHover = onHover
        return v
    }
    func updateNSView(_ v: MouseView, context: Context) {
        v.onClick = onClick
        v.onHover = onHover
    }
}

/// Borderless windows don't reliably expose macOS's own resize edges, so the panel carries
/// an explicit corner grip. Dragging it keeps the top-left pinned and grows down/right.
final class ResizeGripView: NSView {
    private var startFrame: NSRect = .zero
    private var startPoint: NSPoint = .zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startFrame = window.frame
        startPoint = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let now = NSEvent.mouseLocation
        var f = startFrame
        f.size.width = max(260, startFrame.width + (now.x - startPoint.x))
        f.size.height = max(120, startFrame.height - (now.y - startPoint.y))
        f.origin.y = startFrame.maxY - f.size.height     // top edge stays put
        window.setFrame(f, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "tickerFrame")
        NotificationCenter.default.post(name: .tickerDidResize, object: window)
    }
}

extension Notification.Name {
    static let tickerDidResize = Notification.Name("tickerDidResize")
}

struct ResizeGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> ResizeGripView { ResizeGripView() }
    func updateNSView(_ nsView: ResizeGripView, context: Context) {}
}

struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Image(systemName: symbol)
                // Faint was too recessive to find — these are the panel's only controls.
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(hovering ? Palette.ink : Palette.dim)
            MouseArea(onClick: action, onHover: { hovering = $0 })
        }
        .frame(width: 18, height: 18)
        .help(help)
    }
}

struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .overlay(Rectangle().stroke(color.opacity(0.5), lineWidth: 0.5))
            .fixedSize()
    }
}

struct RowView: View {
    let session: Session
    let onTap: () -> Void
    let onMarkRead: () -> Void
    @State private var hovering = false
    @State private var pulse = false

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var contextColor: Color {
        guard let c = session.contextPercent else { return Palette.faint }
        return c >= 85 ? Palette.red : Palette.faint
    }

    var body: some View {
        HStack(spacing: 0) {
            // Status rail — replaces the conventional status dot. One marker, not two.
            Rectangle()
                .fill(session.state.color)
                .frame(width: 3)
                .opacity(session.state == .working && !reduceMotion ? (pulse ? 1.0 : 0.4) : 1.0)
                .animation(
                    session.state == .working && !reduceMotion
                        ? .easeInOut(duration: 1.6).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )

            HStack(spacing: 7) {
                Text(session.name)
                    .font(.system(size: 12,
                                  weight: (session.state.wantsYou || session.isFocused) ? .semibold : .regular,
                                  design: .monospaced))
                    // Dimming means "abandoned", not "not currently generating".
                    .foregroundColor(session.isStale && !session.isFocused ? Palette.dim : Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if session.isFocused { Chip(text: "here", color: Palette.ink) }
                if let tag = session.tag { Chip(text: tag, color: Palette.faint) }

                Spacer(minLength: 4)

                // Idle rows say nothing — absence of text means nothing to report.
                if session.state != .idle {
                    let base = session.labelOverride ?? session.state.label
                    Text(session.detail.map { "\(base) · \($0)" } ?? base)
                        .font(.system(size: 10.5))
                        .foregroundColor(session.state.color)
                        .lineLimit(1)
                        .layoutPriority(1)
                }

                Text(session.contextPercent.map { "\($0)%" } ?? "")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(contextColor)
                    .frame(width: 30, alignment: .trailing)

                // Acknowledge an amber row. Its own mouse view, because the row-wide click
                // handler is an AppKit overlay that would otherwise swallow the press.
                ZStack {
                    if session.state.dismissible {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(hovering ? Palette.ink : Palette.faint)
                        MouseArea(onClick: onMarkRead, onHover: { _ in })
                            .help("Mark as read")
                    }
                }
                .frame(width: 14, height: 16)
            }
            .padding(.leading, 9)
            .padding(.trailing, 8)
        }
        .frame(height: 30)
        .background(hovering ? Color.white.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        // Leave the trailing strip uncovered so the checkmark can receive its own clicks.
        .overlay(
            HStack(spacing: 0) {
                MouseArea(onClick: onTap, onHover: { hovering = $0 })
                Color.clear.frame(width: 22)
            }
        )
        .onAppear { if session.state == .working { pulse = true } }
        .help(session.cwd.isEmpty ? session.name : session.cwd)
    }
}

/// Chrome state that lives outside the session data.
@MainActor
final class UIState: ObservableObject {
    @Published var collapsed = false
}

struct TickerView: View {
    @ObservedObject var fleet: Fleet
    @ObservedObject var ui: UIState

    private var needsAttention: Bool {
        fleet.sessions.contains { $0.state.wantsYou }
    }

    private var counts: String {
        let needs = fleet.sessions.filter { $0.state.wantsYou }.count
        let busy  = fleet.sessions.filter { $0.state == .working }.count
        var parts: [String] = []
        if needs > 0 { parts.append("\(needs) waiting on you") }
        if busy  > 0 { parts.append("\(busy) working") }
        parts.append("\(fleet.sessions.count) total")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header doubles as the drag handle.
            HStack(spacing: 6) {
                Text("CLAUDE SESSIONS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    // Amber means one thing everywhere in this panel: something wants you.
                    .foregroundColor(needsAttention ? Palette.amber : Palette.dim)
                Spacer()
                if !ui.collapsed {
                    Text("ctx")
                        .font(.system(size: 9))
                        .foregroundColor(Palette.faint)
                }
                // AppKit hit targets, not SwiftUI Buttons: a Button in a non-activating panel
                // waits for the window to become key, so the first click appears to do nothing.
                HeaderButton(symbol: ui.collapsed ? "chevron.down" : "chevron.up",
                             help: ui.collapsed ? "Show sessions" : "Collapse to header") {
                    ui.collapsed.toggle()
                }
                HeaderButton(symbol: "xmark", help: "Quit ticker") {
                    NSApp.terminate(nil)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 2)

            Text(counts)
                .font(.system(size: 10))
                .foregroundColor(needsAttention ? Palette.amber.opacity(0.85) : Palette.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            if ui.collapsed {
                Spacer(minLength: 0)
            } else {
                Rectangle().fill(Palette.faint.opacity(0.28)).frame(height: 0.5)

                if let err = fleet.lastError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else if fleet.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("No sessions running.")
                        .font(.system(size: 11))
                        .foregroundColor(Palette.dim)
                    Text("Start one in any terminal.")
                        .font(.system(size: 10))
                        .foregroundColor(Palette.faint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(fleet.sessions) { s in
                            RowView(session: s, onTap: { fleet.focus(s) }, onMarkRead: { fleet.markRead(s) })
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        // The window is user-resizable now, so the content fills whatever size it's given
        // instead of dictating one.
        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Vibrancy alone tracks whatever is behind the panel; the scrim keeps
        // contrast constant over a white terminal or a dark one.
        .background(
            ZStack {
                VisualEffect()
                Color(red: 0.07, green: 0.07, blue: 0.08).opacity(0.72)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .overlay(alignment: .bottomTrailing) {
            if !ui.collapsed {
                ZStack(alignment: .bottomTrailing) {
                    Path { p in
                        for offset in stride(from: 2.0, through: 10.0, by: 4.0) {
                            p.move(to: CGPoint(x: 13, y: offset))
                            p.addLine(to: CGPoint(x: offset, y: 13))
                        }
                    }
                    .stroke(Palette.faint, lineWidth: 1)
                    .frame(width: 15, height: 15)
                    ResizeGrip().frame(width: 16, height: 16)
                }
                .frame(width: 16, height: 16)
                .padding(2)
            }
        }
    }
}

/// Native macOS vibrancy so the panel reads as part of the OS, not a window pretending.
struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Borderless windows refuse key status by default, which swallows clicks before SwiftUI
/// ever sees them. Because this is also a non-activating panel, becoming key never pulls
/// focus away from the terminal you're working in.
final class TickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: TickerPanel!
    let fleet = Fleet()

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon
        fleet.start()

        // No preferredContentSize: the user's chosen size wins, and the list scrolls inside it.
        let controller = NSHostingController(rootView: TickerView(fleet: fleet, ui: ui))

        panel = TickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            // .nonactivatingPanel: clicking the ticker never steals focus from a terminal.
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.minSize = NSSize(width: 260, height: 54)
        panel.maxSize = NSSize(width: 900, height: 2000)
        panel.contentViewController = controller
        // A HUD floating over terminals stays dark regardless of the system theme.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        // Assigning a contentViewController shrinks the window to the SwiftUI fitting size,
        // so the real frame has to be set explicitly afterwards.
        var frame = NSRect(x: 0, y: 0, width: 360, height: 420)
        if let screen = NSScreen.main {
            frame.origin = NSPoint(x: screen.visibleFrame.maxX - frame.width - 18,
                                   y: screen.visibleFrame.maxY - 12 - frame.height)
        }
        if let saved = UserDefaults.standard.string(forKey: "tickerFrame") {
            let r = NSRectFromString(saved)
            // Ignore a saved frame that is degenerate or parked off-screen.
            let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(r) }
            if r.width >= 260, r.height >= 54, onScreen { frame = r }
        }
        panel.setFrame(frame, display: false)
        expandedHeight = max(frame.height, 200)
        panel.orderFrontRegardless()

        // Remember position and size, but never record the collapsed height as the real one.
        for note in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification, .tickerDidResize] {
            NotificationCenter.default.addObserver(forName: note, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isRepositioning else { return }
                    // Dragging the panel taller is a request to see the sessions again.
                    // `.resizable` is in the style mask, so the OS corner resizes the window
                    // even while collapsed hides the SwiftUI grip — without this, that drag
                    // grows a collapsed panel into a tall empty box with no way back except
                    // the chevron. Adopt the dragged height first so applyCollapse(false)
                    // sees no change and leaves the size the user just chose alone.
                    if self.ui.collapsed, self.panel.frame.height > self.collapsedHeight + 20 {
                        self.expandedHeight = self.panel.frame.height
                        self.ui.collapsed = false
                    }
                    if !self.ui.collapsed { self.expandedHeight = self.panel.frame.height }
                    UserDefaults.standard.set(NSStringFromRect(self.panel.frame), forKey: "tickerFrame")
                }
            }
        }

        // Collapsing is manual only — the chevron. The panel never resizes itself based on
        // which app you're in.
        collapseObserver = ui.$collapsed.sink { [weak self] value in
            MainActor.assumeIsolated { self?.applyCollapse(value) }
        }
    }

    private let ui = UIState()
    private var expandedHeight: CGFloat = 420
    private var isRepositioning = false
    private var collapseObserver: Any?
    private let collapsedHeight: CGFloat = 54

    private func applyCollapse(_ value: Bool) {
        let frame = panel.frame
        let top = frame.maxY
        // Capture whatever size the user had chosen before shrinking, so expanding restores it.
        if value, frame.height > collapsedHeight + 20 { expandedHeight = frame.height }
        if !value, expandedHeight < collapsedHeight + 20 { expandedHeight = 420 }
        let height = value ? collapsedHeight : expandedHeight
        guard abs(frame.height - height) > 0.5 else { return }
        isRepositioning = true
        panel.setFrame(NSRect(x: frame.minX, y: top - height, width: frame.width, height: height),
                       display: true, animate: false)
        isRepositioning = false
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    objc_setAssociatedObject(app, "tickerDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
