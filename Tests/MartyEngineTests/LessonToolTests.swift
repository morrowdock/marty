// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import MartyEngine

/// lesson_check and lesson_stream on the engine's own rotation lesson (docs/fixtures/v1 at the pin).
@MainActor
final class LessonToolTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func fixture(_ name: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent("Tests/Fixtures/lessons/\(name)"), encoding: .utf8)
    }
    func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testRotationLessonIsAcceptedWithFilledLines() throws {
        let r = try MartyEngine(outputRoot: nil).lessonCheck(lesson: try fixture("rotation.lesson.json"))
        XCTAssertEqual(r["ok"] as? Bool, true, "\(r)")
        XCTAssertEqual(r["beats"] as? Int, 5)
        let lines = try XCTUnwrap(r["lines"] as? [[String: Any]])
        XCTAssertEqual(lines.count, 5)
        for l in lines { XCTAssertFalse((l["text"] as? String ?? "{").contains("{"), "placeholder left in \(l)") }
        let board = try XCTUnwrap(r["board"] as? [String: Any])
        let ax = try XCTUnwrap((board["values"] as? [String: Any])?["ax"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(ax["value"] as? Double), -2, accuracy: 1e-9, "the last beat turns to 180 degrees")
        XCTAssertEqual((board["controls"] as? [Any])?.count, 1)
        // Deterministic: a second engine gives the same bytes.
        XCTAssertEqual(MartyJSON.data(r), MartyJSON.data(try MartyEngine(outputRoot: nil).lessonCheck(lesson: try object(try fixture("rotation.lesson.json")))))
    }

    func testLessonRefusalsCarryReasonAndLocation() throws {
        let e = MartyEngine(outputRoot: nil)
        // A false claim refuses the whole lesson at that beat.
        let wrong = try fixture("rotation.lesson.json").replacingOccurrences(of: #"{"value":"ax","eq":-1}"#, with: #"{"value":"ax","eq":5}"#)
        let r = try e.lessonCheck(lesson: wrong)
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertEqual(r["reason"] as? String, "check.ax")
        XCTAssertNotNil(r["beat"] as? Int)
        // A typed decimal in a line is refused (owner rule D3).
        let literal = try fixture("rotation.lesson.json").replacingOccurrences(of: "This is triangle ABC.", with: "This is triangle ABC, 1.5 units wide.")
        XCTAssertEqual(try e.lessonCheck(lesson: literal)["reason"] as? String, "text.literal")
        XCTAssertEqual(try e.lessonCheck(lesson: "{not json")["reason"] as? String, "lesson.json")
        XCTAssertEqual(try e.lessonCheck(lesson: ["v": 1, "kind": "assembly"])["reason"] as? String, "lesson.kind")
    }

    func testStreamGivesTheSameBoardAsTheDocument() throws {
        let e = MartyEngine(outputRoot: nil)
        let text = try fixture("rotation.statements.ndjson")
        // Split in the middle of a statement: partial input waits.
        let cut = text.index(text.startIndex, offsetBy: text.count / 2)
        let a = try e.lessonStream(session: nil, chunk: String(text[..<cut]), end: false)
        let id = try XCTUnwrap(a["session"] as? String)
        XCTAssertGreaterThan(try XCTUnwrap(a["unfinishedBytes"] as? Int), 0)
        let b = try e.lessonStream(session: id, chunk: String(text[cut...]), end: true)
        XCTAssertEqual(b["ok"] as? Bool, true, "\(b)")
        let events = ((a["events"] as? [[String: Any]]) ?? []) + ((b["events"] as? [[String: Any]]) ?? [])
        XCTAssertEqual(events.filter { $0["event"] as? String == "lineQueued" }.count, 5)
        XCTAssertTrue(events.contains { $0["event"] as? String == "streamEnded" })
        let doc = try e.lessonCheck(lesson: try fixture("rotation.lesson.json"))
        let streamValues = (b["board"] as? [String: Any])?["values"] ?? [:]
        let docValues = (doc["board"] as? [String: Any])?["values"] ?? [:]
        XCTAssertEqual(MartyJSON.data(streamValues), MartyJSON.data(docValues))
    }

    func testRefusedStatementChangesNothingAndLaterOnesContinue() throws {
        let e = MartyEngine(outputRoot: nil)
        let lines = try fixture("rotation.statements.ndjson").split(separator: "\n").map(String.init)
        let first = try e.lessonStream(session: nil, chunk: lines.prefix(2).joined(separator: "\n") + "\n", end: false)
        let id = try XCTUnwrap(first["session"] as? String)
        let bad = try e.lessonStream(session: id, chunk: #"{"op":"remove","id":"nope"}"# + "\n", end: false)
        XCTAssertEqual(bad["ok"] as? Bool, false)
        // Nothing changed: the same board (values, controls, beat cursor) and no unfinished input.
        XCTAssertEqual(MartyJSON.data(bad["board"] ?? [:]), MartyJSON.data(first["board"] ?? [:]))
        XCTAssertEqual(bad["unfinishedBytes"] as? Int, first["unfinishedBytes"] as? Int)
        let refused = try XCTUnwrap((bad["events"] as? [[String: Any]])?.first { $0["event"] as? String == "refused" })
        XCTAssertNotNil(refused["reason"] as? String)
        let rest = try e.lessonStream(session: id, chunk: lines.dropFirst(2).joined(separator: "\n") + "\n", end: true)
        XCTAssertEqual(rest["ok"] as? Bool, true, "\(rest)")
    }

    func testSessionsAreBounded() throws {
        let e = MartyEngine(outputRoot: nil)
        let first = try XCTUnwrap(try e.lessonStream(session: nil, chunk: "", end: false)["session"] as? String)
        for _ in 0..<MartyEngine.maxLessonSessions { _ = try e.lessonStream(session: nil, chunk: "", end: false) }
        XCTAssertThrowsError(try e.lessonStream(session: first, chunk: "", end: false)) {
            XCTAssertEqual(($0 as? ToolError)?.reason, "lesson.session.unknown")
        }
        XCTAssertThrowsError(try e.lessonStream(session: nil, chunk: String(repeating: " ", count: MartyEngine.maxChunkBytes + 1), end: false)) {
            XCTAssertEqual(($0 as? ToolError)?.reason, "lesson.chunk.bytes")
        }
    }

    /// After a budget refusal the engine ignores the stream until it ends; the tool says so instead of ok: true.
    func testExhaustedStreamIsReported() throws {
        let e = MartyEngine(outputRoot: nil)
        let scene = #"{"scene":{"v":1,"template":"rotate2d","params":{"pts":[[2,1],[4,1],[2,3]],"angle":0}}}"# + "\n"
        let start = try e.lessonStream(session: nil, chunk: scene, end: false)
        let id = try XCTUnwrap(start["session"] as? String)
        // Fill the 32 KiB stream budget with whitespace (every received byte counts).
        var hit = false
        for _ in 0..<3 {
            let r = try e.lessonStream(session: id, chunk: String(repeating: " ", count: 16 * 1024), end: false)
            if (r["events"] as? [[String: Any]])?.contains(where: { $0["reason"] as? String == "lesson.bytes" }) == true { hit = true; break }
        }
        XCTAssertTrue(hit, "the engine's byte budget refusal")
        let later = try e.lessonStream(session: id, chunk: #"{"say":"Hello."}"# + "\n", end: false)
        XCTAssertEqual(later["ok"] as? Bool, false)
        XCTAssertEqual(later["reason"] as? String, "lesson.stream.exhausted")
        XCTAssertEqual(later["exhausted"] as? Bool, true)
        let ended = try e.lessonStream(session: id, chunk: "", end: true)
        XCTAssertEqual(ended["exhausted"] as? Bool, false)
        // After end a new stream in the same session is accepted.
        let again = try e.lessonStream(session: id, chunk: scene, end: false)
        XCTAssertEqual(again["ok"] as? Bool, true, "\(again)")
        XCTAssertTrue((again["events"] as? [[String: Any]])?.contains { $0["event"] as? String == "accepted" } == true)
    }
}
