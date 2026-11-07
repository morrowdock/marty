// SPDX-License-Identifier: Apache-2.0
import Foundation
import MartyEngine

/// A Model Context Protocol server over the stdio transport: one JSON-RPC 2.0 message per line.
/// It handles one request at a time, in order. It opens no network connection and runs no process.
@MainActor
public final class MCPServer {
    public static let name = "marty-mcp"
    public static let version = "0.2.0"
    public static let protocolVersions = ["2025-11-25", "2025-06-18"]

    let engine: MartyEngine

    public init(engine: MartyEngine) { self.engine = engine }

    /// Handles one line. Returns the response line, or nil for a notification.
    public func handle(line: Data) -> Data? {
        guard line.count <= MartyLimits.requestBytes else { return Self.error(id: nil, -32600, "request.bytes") }
        guard let object = try? JSONSerialization.jsonObject(with: line) else { return Self.error(id: nil, -32700, "parse") }
        guard let msg = object as? [String: Any] else {
            // Batches were removed from MCP in 2025-06-18.
            return Self.error(id: nil, -32600, "request.object")
        }
        let id = msg["id"]
        // Only a string or a number is an id we may echo; anything else is answered with id null.
        let validID = id is String || (id as? NSNumber).map({ CFGetTypeID($0) != CFBooleanGetTypeID() }) == true
        guard msg["jsonrpc"] as? String == "2.0", let method = msg["method"] as? String else {
            if msg["method"] == nil, msg["result"] != nil || msg["error"] != nil { return nil }  // a response; we send no requests
            return Self.error(id: validID ? id : nil, -32600, "request.invalid")
        }
        guard let id else { return nil }  // notifications (initialized, cancelled, ...) need no answer
        guard validID else { return Self.error(id: nil, -32600, "request.id") }
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let version = Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]
            return Self.result(id: id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": Self.name, "version": Self.version],
                "instructions": Self.instructions,
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": Tools.all.map(\.definition)])
        case "tools/call":
            guard let name = params["name"] as? String else { return Self.error(id: id, -32602, "params.name") }
            guard let args = (params["arguments"] ?? [String: Any]()) as? [String: Any] else { return Self.error(id: id, -32602, "params.arguments") }
            // An unknown tool is a protocol error in MCP, not a tool result.
            guard Tools.all.contains(where: { $0.name == name }) else { return Self.error(id: id, -32602, "tool.unknown") }
            do {
                return Self.result(id: id, Self.toolResult(try Tools.call(name, args, engine: engine), isError: false))
            } catch let e as ToolError {
                return Self.result(id: id, Self.toolResult(e.report, isError: true))
            } catch {
                return Self.result(id: id, Self.toolResult(ToolError("internal", "\(error)").report, isError: true))
            }
        default:
            return Self.error(id: id, -32601, "method.unknown")
        }
    }

    static let instructions = """
        MartyGraphics engine tools. The engine is the source of truth: it solves motion, checks every number and refuses \
        a wrong document with one stable reason token and the part. Workflow: catalog -> explain (as needed) -> write a \
        document -> check -> repair from the exact reason -> render. Use patch for what-if questions. For a 2D \
        beat-by-beat lesson, use lesson_check (whole document) or lesson_stream (one statement at a time). Never state a \
        number that the engine did not report.
        """

    /// The answer to a line over the request bound (`LineSplitter` gives nil for it).
    public static var tooLarge: Data { error(id: nil, -32600, "request.bytes") }

    static func toolResult(_ object: [String: Any], isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": MartyJSON.string(object)]],
         "structuredContent": MartyJSON.sanitized(object),
         "isError": isError]
    }

    static func result(id: Any, _ result: [String: Any]) -> Data {
        MartyJSON.data(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func error(id: Any?, _ code: Int, _ message: String) -> Data {
        MartyJSON.data(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }
}

/// Splits standard input into lines with a bound. A line over the bound is answered with an error and skipped.
public struct LineSplitter {
    var buffer = Data()
    var discarding = false
    public let limit: Int

    public init(limit: Int = MartyLimits.requestBytes) { self.limit = limit }

    /// At end of input: the last line when it had no newline (and is not blank or too long).
    public mutating func finish() -> Data? {
        defer { buffer.removeAll(); discarding = false }
        guard !discarding, buffer.count <= limit, !buffer.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) else { return nil }
        return buffer
    }

    /// Adds bytes; returns complete lines (`nil` entries mark a line that was too long).
    public mutating func feed(_ chunk: Data) -> [Data?] {
        var out: [Data?] = []
        var rest = chunk[...]
        while let nl = rest.firstIndex(of: 0x0A) {
            let piece = rest[rest.startIndex..<nl]
            rest = rest[rest.index(after: nl)...]
            if discarding { discarding = false; buffer.removeAll(); continue }
            buffer.append(contentsOf: piece)
            if buffer.count > limit { out.append(nil) } else if !buffer.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { out.append(buffer) }
            buffer.removeAll(keepingCapacity: true)
        }
        if !discarding {
            buffer.append(contentsOf: rest)
            if buffer.count > limit { out.append(nil); buffer.removeAll(); discarding = true }
        }
        return out
    }
}
