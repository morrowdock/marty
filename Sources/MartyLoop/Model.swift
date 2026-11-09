// SPDX-License-Identifier: Apache-2.0
import Foundation

/// One model answer, with what the adapter could measure.
public struct ModelReply {
    public var text: String
    public var seconds: Double
    /// Adapter-specific facts for the receipt (token usage, cost equivalent, error flags). Never prompt text.
    public var meta: [String: Any]
    public init(text: String, seconds: Double, meta: [String: Any] = [:]) { self.text = text; self.seconds = seconds; self.meta = meta }
}

/// Anything that turns a system prompt and one user message into text. Each call is independent: the loop sends the
/// whole context every time, so a model never relies on hidden session state.
public protocol ModelAdapter {
    /// For the receipt, for example `claude-cli:claude-haiku-5-5`.
    var id: String { get }
    func reply(system: String, user: String) throws -> ModelReply
    /// One research call with web search and web fetch only (no other tool), at most `limits.maxTurns` turns. An
    /// adapter without web tools throws `adapter.research.unsupported`; the loop then goes on without a fact table.
    func research(system: String, user: String, limits: ResearchLimits) throws -> ModelReply
    /// Whether `research` can run (the loop skips the phase, with no call, when it cannot).
    var supportsResearch: Bool { get }
}

/// Bounds of the research call.
public struct ResearchLimits {
    /// Agent turns of the research call (each search or fetch takes a turn).
    public var maxTurns: Int
    /// Domains whose pages the research call may not fetch and that never count as a source (our own repositories
    /// hold grading material).
    public var blockedDomains: [String]
    public static let defaultBlocked = ["github.com", "raw.githubusercontent.com", "gist.github.com", "githubusercontent.com"]
    public init(maxTurns: Int = 12, blockedDomains: [String] = ResearchLimits.defaultBlocked) {
        self.maxTurns = maxTurns; self.blockedDomains = blockedDomains
    }
}

extension ModelAdapter {
    public var supportsResearch: Bool { false }
    public func research(system: String, user: String, limits: ResearchLimits) throws -> ModelReply {
        throw AdapterError(reason: "adapter.research.unsupported", detail: "\(id) has no web tools")
    }
}

public struct AdapterError: Error, CustomStringConvertible {
    public let reason: String
    public let detail: String
    public var description: String { "\(reason): \(detail)" }
}

/// The local Claude Code CLI in print mode (uses the logged-in subscription; no API key, no paid API).
/// Every call is a fresh process in a new empty working directory with no tools, no MCP servers and no session
/// persistence. The prompt goes in on standard input; nothing the model writes is ever run.
public struct ClaudeCLIAdapter: ModelAdapter {
    public let model: String
    public let executable: URL
    public let timeout: TimeInterval
    public var id: String { "claude-cli:\(model)" }

    public init(model: String, executable: URL? = nil, timeout: TimeInterval = 900) throws {
        guard model.range(of: #"^[a-z0-9][a-z0-9.\-]{0,63}$"#, options: .regularExpression) != nil else {
            throw AdapterError(reason: "adapter.model", detail: "model ids are lower-case letters, digits, '.' and '-'")
        }
        self.model = model
        self.timeout = timeout
        if let e = executable { self.executable = e }
        else if let found = Self.findInPath("claude") { self.executable = found }
        else { throw AdapterError(reason: "adapter.claude.missing", detail: "the `claude` command is not on PATH") }
    }

    static func findInPath(_ name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        // Absolute PATH entries only: a relative entry would resolve against the current directory.
        for dir in path.split(separator: ":") where dir.hasPrefix("/") {
            let u = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        return nil
    }

    /// The child gets only these variables. In particular no ANTHROPIC_API_KEY (which would bill the paid API instead
    /// of the logged-in subscription) and nothing from a parent Claude Code session.
    /// Kept: what the subscription login needs (keychain via HOME/USER, or a `claude setup-token` token in
    /// CLAUDE_CODE_OAUTH_TOKEN, and CLAUDE_CONFIG_DIR), proxies and CA certificates, and the locale.
    static let environmentAllowlist = ["HOME", "PATH", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
                                       "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR",
                                       "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy",
                                       "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE"]
    /// After the child exits, how long to wait for its pipes to close (a grandchild can keep them open).
    static let drainGrace: TimeInterval = 5
    /// Largest reply envelope read from the child; the rest is drained and dropped.
    static let maxOutputBytes = 8 << 20

    public func reply(system: String, user: String) throws -> ModelReply {
        try run(system: system, user: user, tools: nil)
    }

    /// The research call: the built-in WebSearch and WebFetch tools only, allowed without a prompt, WebFetch denied
    /// on the blocked domains, and at most `limits.maxTurns` turns. Everything else is as in `reply`.
    public func research(system: String, user: String, limits: ResearchLimits) throws -> ModelReply {
        try run(system: system, user: user, tools: limits)
    }
    public var supportsResearch: Bool { true }

    /// The CLI arguments: no tools at all for a normal call; for a research call only WebSearch and WebFetch.
    static func arguments(model: String, systemFile: String, research: ResearchLimits?) -> [String] {
        var a = ["-p", "--model", model]
        if let r = research {
            a += ["--tools", "WebSearch,WebFetch", "--allowedTools", "WebSearch,WebFetch",
                  "--disallowedTools", r.blockedDomains.flatMap { ["WebFetch(domain:\($0))", "WebFetch(domain:*.\($0))"] }.joined(separator: ","),
                  "--max-turns", String(max(1, min(r.maxTurns, 40)))]
        } else {
            a += ["--tools", ""]
        }
        // A research call streams its events, so Marty can count each web tool use and stop at the limit.
        let format = research != nil ? ["--output-format", "stream-json", "--verbose"] : ["--output-format", "json"]
        return a + ["--strict-mcp-config", "--disable-slash-commands", "--setting-sources", "", "--no-session-persistence"]
            + format + ["--system-prompt-file", systemFile]
    }

    /// The web tool uses (WebSearch, WebFetch) in one stream-json line: tool_use blocks of an assistant message.
    static func webToolUses(_ line: Data) -> [String: Int] {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [:] }
        return webToolUses(o)
    }

    /// The "ROW {...}" lines in an assistant event's text blocks, as row objects.
    static func rowLines(_ o: [String: Any]) -> [Any] {
        guard o["type"] as? String == "assistant",
              let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [] }
        var out: [Any] = []
        for c in content where c["type"] as? String == "text" {
            for line in (c["text"] as? String ?? "").split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("ROW "), let row = try? JSONSerialization.jsonObject(with: Data(t.dropFirst(4).utf8)) as? [String: Any] else { continue }
                out.append(row)
            }
        }
        return out
    }

    /// Adds a ROW to the partial table: a row with the id of an earlier one replaces it, an identical row is skipped,
    /// and at most `FactTable.maxRows` distinct rows are kept.
    static func addRow(_ row: Any, to rows: inout [Any]) {
        let id = (row as? [String: Any])?["id"] as? String
        if let id, let n = rows.firstIndex(where: { ($0 as? [String: Any])?["id"] as? String == id }) { rows[n] = row; return }
        func data(_ o: Any) -> Data? { try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) }
        let d = data(row)
        if rows.contains(where: { data($0) == d }) { return }
        if rows.count < FactTable.maxRows { rows.append(row) }
    }

    /// The text without its ROW lines (the final table is parsed from the rest).
    static func withoutRowLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("ROW ") }.joined(separator: "\n")
    }

    static func webToolUses(_ o: [String: Any]) -> [String: Int] {
        guard o["type"] as? String == "assistant",
              let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [:] }
        var out: [String: Int] = [:]
        for c in content where c["type"] as? String == "tool_use" {
            if let n = c["name"] as? String, n == "WebSearch" || n == "WebFetch" { out[n, default: 0] += 1 }
        }
        return out
    }

    func run(system: String, user: String, tools: ResearchLimits?) throws -> ModelReply {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("marty-model-\(UUID().uuidString)", isDirectory: true)
        let ctx = fm.temporaryDirectory.appendingPathComponent("marty-prompt-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false)
        try fm.createDirectory(at: ctx, withIntermediateDirectories: false)
        let systemFile = ctx.appendingPathComponent("system.txt")
        try Data(system.utf8).write(to: systemFile)

        let p = Process()
        p.executableURL = executable
        p.currentDirectoryURL = work
        let env = ProcessInfo.processInfo.environment
        p.environment = env.filter { Self.environmentAllowlist.contains($0.key) }
        // No tools (a research call: web search and fetch only), no MCP servers, no slash commands, no
        // user/project/local settings (so no hooks or plugins), no session file. The system prompt replaces Claude
        // Code's own.
        p.arguments = Self.arguments(model: model, systemFile: systemFile.path, research: tools)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        // A child that exits without reading must give us EPIPE, not a SIGPIPE that kills this process.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let t0 = Date()
        do { try p.run() } catch { try? fm.removeItem(at: work); try? fm.removeItem(at: ctx); throw error }

        // Reading and writing run on their own threads; the timeout is on the child's exit. Only the writer closes stdin.
        final class Box: @unchecked Sendable {
            var out = Data(), err = Data(), toolUses = 0, overBudget = false
            /// A research call's stream, parsed from every byte (not only the kept output): the unfinished line, the
            /// counts per tool, and the last "result" event.
            var line = Data(), lineTooLong = false, counts: [String: Int] = [:], result: Data? = nil
            /// Rows the model wrote as "ROW {...}" lines in its text while researching (at most 20).
            var rows: [Any] = []
        }
        let box = Box()
        let group = DispatchGroup()     // the two pipe readers
        let exited = DispatchGroup()    // the child's exit
        func drain(_ h: FileHandle, observe: ((Data) -> Void)? = nil, _ keep: @escaping (Data) -> Void) {
            group.enter()
            DispatchQueue.global().async {
                var kept = 0
                while true {
                    let d = h.availableData
                    if d.isEmpty { break }
                    observe?(d)
                    if kept < Self.maxOutputBytes { let part = d.prefix(Self.maxOutputBytes - kept); keep(part); kept += part.count }
                }
                group.leave()
            }
        }
        let lock = NSLock()
        let toolLimit = tools.map { max(1, min($0.maxTurns, 40)) }
        // A research call: every complete stream line is parsed as it arrives (bounded: a line over the output cap is
        // skipped), its web tool uses counted and the last "result" event kept; past the limit, the child is stopped.
        // One complete stream line (called with the lock held): parsed once; its web tool uses counted; a top-level
        // "result" event kept; past the limit, the child is stopped.
        func handle(_ line: Data, limit: Int) {
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            for (k, v) in Self.webToolUses(o) { box.counts[k, default: 0] += v; box.toolUses += v }
            if o["type"] as? String == "result" { box.result = line }
            for row in Self.rowLines(o) { Self.addRow(row, to: &box.rows) }
            if box.toolUses > limit, !box.overBudget { box.overBudget = true; if p.isRunning { p.terminate() } }
        }
        let observe: ((Data) -> Void)? = toolLimit.map { limit in { d in
            lock.lock()
            for byte in d {
                if byte == 10 {
                    if !box.lineTooLong { handle(box.line, limit: limit) }
                    box.line.removeAll(keepingCapacity: true); box.lineTooLong = false
                } else if !box.lineTooLong {
                    box.line.append(byte)
                    if box.line.count > Self.maxOutputBytes { box.lineTooLong = true; box.line.removeAll() }
                }
            }
            lock.unlock()
        } }
        drain(stdout.fileHandleForReading, observe: observe) { d in lock.lock(); box.out.append(d); lock.unlock() }
        drain(stderr.fileHandleForReading) { d in lock.lock(); if box.err.count < 4096 { box.err.append(d.prefix(4096)) }; lock.unlock() }
        DispatchQueue.global().async {
            // EPIPE (the child exited without reading) ends the write; F_SETNOSIGPIPE keeps it from being a signal.
            try? stdin.fileHandleForWriting.write(contentsOf: Data(user.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        exited.enter()
        DispatchQueue.global().async { p.waitUntilExit(); exited.leave() }

        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            p.terminate()
            // Signal only a child that has not exited yet, so a reaped PID (possibly reused) is never hit.
            if exited.wait(timeout: .now() + 5) == .timedOut, p.isRunning { kill(p.processIdentifier, SIGKILL) }
            _ = exited.wait(timeout: .now() + 5)
        }
        // After a normal exit, give the pipes a short grace, then use what was read (a grandchild may hold them open).
        if !timedOut { _ = group.wait(timeout: .now() + Self.drainGrace) }
        try? fm.removeItem(at: work); try? fm.removeItem(at: ctx)
        let seconds = Date().timeIntervalSince(t0)
        lock.lock()
        // A last line without a newline.
        if let limit = toolLimit, !box.line.isEmpty, !box.lineTooLong { handle(box.line, limit: limit) }
        let out = box.out, err = box.err, overBudget = box.overBudget, streamCounts = box.counts, streamResult = box.result, streamRows = box.rows
        lock.unlock()
        // The rows the model wrote so far as a partial table (the call hit a limit or its final table is unreadable).
        func partial(_ why: String) -> ModelReply {
            let text = String(decoding: (try? JSONSerialization.data(withJSONObject: ["needed": true, "rows": streamRows])) ?? Data(), as: UTF8.self)
            return ModelReply(text: text, seconds: Date().timeIntervalSince(t0),
                              meta: ["partial": true, "partialCause": why, "exit": p.isRunning ? -1 : Int(p.terminationStatus),
                                     "webTools": ["web_search_requests": streamCounts["WebSearch"] ?? 0, "web_fetch_requests": streamCounts["WebFetch"] ?? 0]])
        }
        // A research call that hung keeps the rows it wrote; any other timeout is an error.
        if timedOut {
            if tools != nil, !streamRows.isEmpty { return partial("timeout") }
            throw AdapterError(reason: "adapter.timeout", detail: "no answer in \(Int(timeout)) s")
        }
        // Stopped at the limit: the rows the model wrote so far make a partial table; with none, the call failed.
        if overBudget {
            guard !streamRows.isEmpty else { throw AdapterError(reason: "adapter.research.turns", detail: "more than \(toolLimit ?? 0) web tool uses") }
            return partial("web tool limit")
        }
        // A research call's stream: the web tool uses counted from its events, the result from its last "result" event.
        var counted: [String: Int]? = nil
        var envData = out
        if tools != nil {
            counted = ["WebSearch": streamCounts["WebSearch"] ?? 0, "WebFetch": streamCounts["WebFetch"] ?? 0]
            envData = streamResult ?? Data()
        }
        guard let env = try? JSONSerialization.jsonObject(with: envData) as? [String: Any] else {
            // A research call that ended without a result event (a crash) keeps the rows it wrote.
            if tools != nil, !streamRows.isEmpty { return partial("no result event") }
            throw AdapterError(reason: "adapter.output", detail: "exit \(p.terminationStatus): " + String(decoding: err.suffix(400), as: UTF8.self))
        }
        var meta: [String: Any] = ["exit": Int(p.terminationStatus)]
        for key in ["is_error", "total_cost_usd", "duration_ms", "num_turns", "stop_reason"] { if let v = env[key] { meta[key] = v } }
        if let u = env["usage"] as? [String: Any] {
            meta["usage"] = u.filter { ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].contains($0.key) }
            if let t = u["server_tool_use"] as? [String: Any] {
                meta["webTools"] = t.filter { ["web_search_requests", "web_fetch_requests"].contains($0.key) }
            }
        }
        if let counted { meta["webTools"] = ["web_search_requests": counted["WebSearch"] ?? 0, "web_fetch_requests": counted["WebFetch"] ?? 0] }
        if tools != nil {
            // The CLI's own turn limit ends a research call like Marty's limit: the rows so far, or a limit failure.
            let subtype = env["subtype"] as? String ?? ""
            if subtype == "error_max_turns" {
                guard !streamRows.isEmpty else { throw AdapterError(reason: "adapter.research.turns", detail: "the CLI turn limit (\(toolLimit ?? 0))") }
                return partial("turn limit")
            }
            if (env["is_error"] as? Bool) == true, !streamRows.isEmpty { return partial("error") }
        }
        if (env["is_error"] as? Bool) == true {
            throw AdapterError(reason: "adapter.error", detail: String((env["result"] as? String ?? "").prefix(400)))
        }
        var text = env["result"] as? String ?? ""
        if tools != nil {
            // ROW lines before the final table are not part of it; an unreadable final table falls back to the rows.
            text = Self.withoutRowLines(text)
            // The final table must be a table ("rows" a list, or "needed": false), not just any JSON object.
            if !FactTable.isTableShaped(ReplyJSON.object(text)), !streamRows.isEmpty { return partial("final table unreadable") }
        }
        return ModelReply(text: text, seconds: seconds, meta: meta)
    }
}

/// Replays fixed answers in order: for tests and for re-running a recorded session without a model.
public final class ScriptedAdapter: ModelAdapter {
    public let id: String
    private var replies: [String]
    public private(set) var prompts: [(system: String, user: String)] = []

    private var researchReplies: [String]?
    public private(set) var researchPrompts: [(system: String, user: String)] = []

    /// `research`: replies for research calls; nil means this adapter has no web tools.
    public init(id: String = "scripted", replies: [String], research: [String]? = nil) {
        self.id = id; self.replies = replies; self.researchReplies = research
    }

    public func reply(system: String, user: String) throws -> ModelReply {
        prompts.append((system, user))
        guard !replies.isEmpty else { throw AdapterError(reason: "adapter.scripted.empty", detail: "no more scripted replies") }
        return ModelReply(text: replies.removeFirst(), seconds: 0)
    }

    public var supportsResearch: Bool { researchReplies != nil }

    public func research(system: String, user: String, limits: ResearchLimits) throws -> ModelReply {
        guard researchReplies != nil else { throw AdapterError(reason: "adapter.research.unsupported", detail: "\(id) has no web tools") }
        researchPrompts.append((system, user))
        guard !(researchReplies!.isEmpty) else { throw AdapterError(reason: "adapter.scripted.empty", detail: "no more research replies") }
        return ModelReply(text: researchReplies!.removeFirst(), seconds: 0, meta: ["webTools": ["web_search_requests": 0]])
    }
}
