// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
import MartyEngine
@testable import MartyMCP

@MainActor
final class MCPServerTests: XCTestCase {
    func send(_ server: MCPServer, _ message: [String: Any]) throws -> [String: Any]? {
        let line = try JSONSerialization.data(withJSONObject: message)
        guard let reply = server.handle(line: line) else { return nil }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }

    func call(_ server: MCPServer, _ name: String, _ args: [String: Any]) throws -> (isError: Bool, result: [String: Any]) {
        let r = try XCTUnwrap(try send(server, ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": name, "arguments": args]]))
        let result = try XCTUnwrap(r["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        // The text content is the same JSON as the structured content.
        let text = try XCTUnwrap(((result["content"] as? [[String: Any]])?.first)?["text"] as? String)
        XCTAssertEqual(text, MartyJSON.string(structured))
        return (result["isError"] as? Bool ?? false, structured)
    }

    func testInitializeAndList() throws {
        let s = MCPServer(engine: MartyEngine(outputRoot: nil))
        let i = try XCTUnwrap(try send(s, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                            "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]]]))
        let result = try XCTUnwrap(i["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "marty-mcp")
        let newer = try XCTUnwrap(try send(s, ["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "2099-01-01"]]))
        XCTAssertEqual((newer["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
        XCTAssertNil(try send(s, ["jsonrpc": "2.0", "method": "notifications/initialized"]))
        let list = try XCTUnwrap(try send(s, ["jsonrpc": "2.0", "id": "a", "method": "tools/list"]))
        XCTAssertEqual(list["id"] as? String, "a")
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["catalog", "explain", "check", "component_check", "patch", "render", "lesson_check", "lesson_stream"])
        for t in tools { XCTAssertEqual((t["inputSchema"] as? [String: Any])?["type"] as? String, "object") }
        XCTAssertNotNil((try send(s, ["jsonrpc": "2.0", "id": 3, "method": "ping"]))?["result"])
    }

    func testProtocolErrors() throws {
        let s = MCPServer(engine: MartyEngine(outputRoot: nil))
        func code(_ line: String) throws -> Int? {
            let reply = try XCTUnwrap(s.handle(line: Data(line.utf8)))
            return ((try JSONSerialization.jsonObject(with: reply) as? [String: Any])?["error"] as? [String: Any])?["code"] as? Int
        }
        XCTAssertEqual(try code("{oops"), -32700)
        XCTAssertEqual(try code("[1,2]"), -32600)
        XCTAssertEqual(try code(#"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#), -32601)
        XCTAssertEqual(try code(#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#), -32600)
        // A response (we send no requests) gets no answer, with or without an id.
        XCTAssertNil(s.handle(line: Data(#"{"jsonrpc":"2.0","id":5,"result":{}}"#.utf8)))
        // An id that is not a string or number is never echoed.
        let odd = try XCTUnwrap(s.handle(line: Data(#"{"jsonrpc":"2.0","id":{"x":1}}"#.utf8)))
        XCTAssertTrue(String(decoding: odd, as: UTF8.self).contains(#""id":null"#))
        XCTAssertEqual(try code(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#), -32602)
        // Hostile nesting within the line limit is refused, not a crash.
        XCTAssertEqual(try code(String(repeating: "[", count: 200_000)), -32700)
        let deep = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"check","arguments":{"document":"#
            + String(repeating: #"{"a":"#, count: 100_000) + "1" + String(repeating: "}", count: 100_004)
        XCTAssertNotNil(s.handle(line: Data(deep.utf8)))
    }

    func testToolCallsAndErrors() throws {
        let s = MCPServer(engine: MartyEngine(outputRoot: nil))
        let doc: [String: Any] = ["v": 1, "kind": "assembly", "title": "Pair", "units": "mm",
                                  "parts": [["id": "g", "use": "spurPair"]]]
        let ok = try call(s, "check", ["document": doc])
        XCTAssertFalse(ok.isError)
        XCTAssertEqual(ok.result["ok"] as? Bool, true)
        let refused = try call(s, "check", ["document": ["v": 1, "kind": "assembly"]])
        XCTAssertFalse(refused.isError, "a refusal is a result, not a tool error")
        XCTAssertEqual(refused.result["ok"] as? Bool, false)
        XCTAssertNotNil(refused.result["reason"] as? String)

        XCTAssertEqual(try call(s, "check", ["document": doc, "extra": 1]).result["error"] as? String, "args.unknown.extra")
        XCTAssertEqual(try call(s, "check", ["document": doc, "bad key\u{1F600}\"x": 1]).result["error"] as? String, "args.unknown.bad_key__x")
        XCTAssertEqual(try call(s, "explain", [:]).result["error"] as? String, "args.missing.id")
        let unknown = try XCTUnwrap(try send(s, ["jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": ["name": "nope", "arguments": [:]]]))
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32602, "an unknown tool is a protocol error")
        // Clients that send null for every optional argument mean "not given".
        let nulls = try call(s, "check", ["document": doc, "ref": NSNull(), "components": NSNull()])
        XCTAssertFalse(nulls.isError, "\(nulls.result)")
        XCTAssertEqual(nulls.result["ok"] as? Bool, true)
        XCTAssertEqual(try call(s, "catalog", ["compact": 1]).result["error"] as? String, "args.type.compact")
        XCTAssertEqual(try call(s, "render", ["document": doc]).result["error"] as? String, "render.disabled")
        XCTAssertTrue(try call(s, "check", ["ref": "sha256:0"]).isError)
        let what = try call(s, "patch", ["ref": try XCTUnwrap(ok.result["ref"] as? String), "patch": ["parts": ["g": ["with": ["wheelTeeth": 48]]]]])
        XCTAssertEqual(what.result["ok"] as? Bool, true, "\(what.result)")
    }

    func testLineSplitter() {
        var s = LineSplitter(limit: 8)
        XCTAssertEqual(s.feed(Data("abc\nde".utf8)), [Data("abc".utf8)])
        XCTAssertEqual(s.feed(Data("f\n\n  \n".utf8)), [Data("def".utf8)])
        // A line over the limit gives one nil, and the rest of that line is skipped.
        XCTAssertEqual(s.feed(Data("123456789".utf8)), [nil])
        XCTAssertEqual(s.feed(Data("more\nok\n".utf8)), [Data("ok".utf8)])
        XCTAssertEqual(s.feed(Data("123456789\nok\n".utf8)), [nil, Data("ok".utf8)])
        XCTAssertEqual(s.feed(Data("tail".utf8)), [])
        XCTAssertEqual(s.finish(), Data("tail".utf8))
        XCTAssertNil(s.finish())
        _ = s.feed(Data("123456789".utf8))
        XCTAssertNil(s.finish(), "an overlong last line was already answered")
    }
}

/// The built server in fresh processes: the same input gives the same bytes, and the process ends at end of input.
final class MCPProcessTests: XCTestCase {
    var binary: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("marty-mcp") }

    func run(_ input: String, _ args: [String] = ["--no-render"]) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = Pipe()
        try p.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A real client keeps standard input open and waits for each answer; the server must answer a short line at once.
    func testAnswersWhileInputStaysOpen() throws {
        let p = Process()
        p.executableURL = binary
        p.arguments = ["--no-render"]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = Pipe()
        try p.run()
        defer { if p.isRunning { p.terminate() } }
        let got = DispatchSemaphore(value: 0)
        var first = Data()
        DispatchQueue.global().async {
            while !first.contains(0x0A) {
                let d = stdout.fileHandleForReading.availableData
                if d.isEmpty { break }
                first.append(d)
            }
            got.signal()
        }
        stdin.fileHandleForWriting.write(Data((#"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n").utf8))
        XCTAssertEqual(got.wait(timeout: .now() + 10), .success, "no answer while standard input stays open")
        XCTAssertTrue(String(decoding: first, as: UTF8.self).hasPrefix(#"{"id":1,"jsonrpc":"2.0","result":{}}"#), String(decoding: first, as: UTF8.self))
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    func testSessionIsReproducibleAcrossProcesses() throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path), binary.path)
        let doc = #"{"v":1,"kind":"assembly","title":"Pair","units":"mm","parts":[{"id":"g","use":"spurPair","with":{"wheelTeeth":40}}]}"#
        let bad = #"{"v":1,"kind":"assembly","title":"Bad","units":"mm","parts":[{"id":"g","shape":{"gear":{"teeth":3,"module":2,"width":5}}}]}"#
        let input = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"catalog","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"check","arguments":{"document":\#(doc)}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"check","arguments":{"document":\#(bad)}}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"explain","arguments":{"id":"bladeRow"}}}"#,
            String(repeating: "x", count: MartyLimits.requestBytes + 10),
            #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#,
        ].joined(separator: "\n") + "\n"
        // A last line without a newline is still answered at end of input.
        XCTAssertTrue(try run(#"{"jsonrpc":"2.0","id":8,"method":"ping"}"#).out.contains(#""id":8"#))
        let a = try run(input), b = try run(input)
        XCTAssertEqual(a.status, 0)
        XCTAssertEqual(a.out, b.out)
        let lines = a.out.split(separator: "\n")
        XCTAssertEqual(lines.count, 8, a.out)  // the notification has no answer
        XCTAssertTrue(lines[4].contains(#""reason":"part.gear.teeth""#), String(lines[4]))
        XCTAssertTrue(lines[6].contains(#""message":"request.bytes""#), String(lines[6]))
        XCTAssertTrue(lines[7].contains(#""id":7"#))
    }
}
