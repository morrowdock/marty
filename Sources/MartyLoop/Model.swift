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
                  "--disallowedTools", r.blockedDomains.map { "WebFetch(domain:\($0))" }.joined(separator: ","),
                  "--max-turns", String(max(1, min(r.maxTurns, 40)))]
        } else {
            a += ["--tools", ""]
        }
        return a + ["--strict-mcp-config", "--disable-slash-commands", "--setting-sources", "", "--no-session-persistence",
                    "--output-format", "json", "--system-prompt-file", systemFile]
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
        final class Box: @unchecked Sendable { var out = Data(), err = Data() }
        let box = Box()
        let group = DispatchGroup()     // the two pipe readers
        let exited = DispatchGroup()    // the child's exit
        func drain(_ h: FileHandle, _ keep: @escaping (Data) -> Void) {
            group.enter()
            DispatchQueue.global().async {
                var kept = 0
                while true {
                    let d = h.availableData
                    if d.isEmpty { break }
                    if kept < Self.maxOutputBytes { let part = d.prefix(Self.maxOutputBytes - kept); keep(part); kept += part.count }
                }
                group.leave()
            }
        }
        let lock = NSLock()
        drain(stdout.fileHandleForReading) { d in lock.lock(); box.out.append(d); lock.unlock() }
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
        if timedOut { throw AdapterError(reason: "adapter.timeout", detail: "no answer in \(Int(timeout)) s") }
        let seconds = Date().timeIntervalSince(t0)
        lock.lock(); let out = box.out, err = box.err; lock.unlock()
        guard let env = try? JSONSerialization.jsonObject(with: out) as? [String: Any] else {
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
        if (env["is_error"] as? Bool) == true {
            throw AdapterError(reason: "adapter.error", detail: String((env["result"] as? String ?? "").prefix(400)))
        }
        return ModelReply(text: env["result"] as? String ?? "", seconds: seconds, meta: meta)
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
