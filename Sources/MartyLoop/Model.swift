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
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let u = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        return nil
    }

    public func reply(system: String, user: String) throws -> ModelReply {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("marty-model-\(UUID().uuidString)", isDirectory: true)
        let ctx = fm.temporaryDirectory.appendingPathComponent("marty-prompt-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false)
        try fm.createDirectory(at: ctx, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: work); try? fm.removeItem(at: ctx) }
        let systemFile = ctx.appendingPathComponent("system.txt")
        try Data(system.utf8).write(to: systemFile)

        let p = Process()
        p.executableURL = executable
        p.currentDirectoryURL = work
        p.arguments = ["-p", "--model", model, "--tools", "", "--strict-mcp-config", "--disable-slash-commands",
                       "--no-session-persistence", "--output-format", "json", "--system-prompt-file", systemFile.path]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        let t0 = Date()
        try p.run()
        // Read both pipes while the process runs, so a large answer cannot fill a pipe and stall it.
        var out = Data(), err = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { out = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { err = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        stdin.fileHandleForWriting.write(Data(user.utf8))
        try? stdin.fileHandleForWriting.close()
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            throw AdapterError(reason: "adapter.timeout", detail: "no answer in \(Int(timeout)) s")
        }
        p.waitUntilExit()
        let seconds = Date().timeIntervalSince(t0)
        guard let env = try? JSONSerialization.jsonObject(with: out) as? [String: Any] else {
            throw AdapterError(reason: "adapter.output", detail: "exit \(p.terminationStatus): " + String(decoding: err.suffix(400), as: UTF8.self))
        }
        var meta: [String: Any] = ["exit": Int(p.terminationStatus)]
        for key in ["is_error", "total_cost_usd", "duration_ms", "num_turns", "stop_reason"] { if let v = env[key] { meta[key] = v } }
        if let u = env["usage"] as? [String: Any] {
            meta["usage"] = u.filter { ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].contains($0.key) }
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

    public init(id: String = "scripted", replies: [String]) { self.id = id; self.replies = replies }

    public func reply(system: String, user: String) throws -> ModelReply {
        prompts.append((system, user))
        guard !replies.isEmpty else { throw AdapterError(reason: "adapter.scripted.empty", detail: "no more scripted replies") }
        return ModelReply(text: replies.removeFirst(), seconds: 0)
    }
}
