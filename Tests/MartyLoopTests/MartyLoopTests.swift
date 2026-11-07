// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
import MartyEngine
@testable import MartyLoop

@MainActor
final class MartyLoopTests: XCTestCase {
    func tempOut() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("marty-loop-tests-\(UUID().uuidString)", isDirectory: true)
    }

    func testPromptExamplesAreAccepted() throws {
        let r = try MartyEngine(outputRoot: nil).check(document: MartyExamples.formatExample, ref: nil, components: [])
        XCTAssertEqual(r["ok"] as? Bool, true, "\(r)")
    }

    /// A gear reduction document, as a model might write it (test data only; not a prompt example).
    static let spurReduction = #"{"v":1,"kind":"assembly","title":"Spur gear reduction","units":"mm","parts":[{"id":"pair","use":"spurPair","with":{"pinionTeeth":12,"wheelTeeth":36}}],"steps":[{"say":"A small pinion drives a larger wheel.","camera":"hero"},{"say":"Input: the pinion (12 teeth) turns once.","highlight":["pair.pinion"],"spin":1},{"say":"The wheel (36 teeth) turns 12/36 = 1/3 of a turn, the other way.","highlight":["pair.wheel"],"spin":1}]}"#

    func testReplyJSON() {
        XCTAssertEqual(ReplyJSON.object(#"{"a":1}"#)?["a"] as? Int, 1)
        XCTAssertEqual(ReplyJSON.object("Here:\n```json\n{\"a\": 2}\n```\nDone.")?["a"] as? Int, 2)
        XCTAssertEqual(ReplyJSON.object("text {\"a\": 3} text")?["a"] as? Int, 3)
        XCTAssertNil(ReplyJSON.object("no json"))
    }

    /// A scripted session: a refused first attempt, a repair from the exact reason, a follow-up patch and an answer.
    func testLoopRepairsFromTheExactReasonAndRecordsEverything() throws {
        let plan = #"{"inScope": true, "subject": "gear reduction", "beats": ["pinion drives wheel"], "components": ["spurPair", "wormGear"], "primitives": ["gear"], "honesty": ""}"#
        let bad = #"{"document": {"v": 1, "kind": "assembly", "title": "Gears", "units": "mm", "parts": [{"id": "pair", "use": "spurPair", "with": {"wheelTeeth": 999}}]}, "components": []}"#
        let good = "```json\n{\"document\": \(Self.spurReduction), \"components\": []}\n```"
        let patch = #"{"patch": {"parts": {"pair": {"with": {"pinionTeeth": 12, "wheelTeeth": 72}}}}}"#
        let answer = "The wheel now turns 12/72 = 1/6 of a turn per pinion turn."
        let model = ScriptedAdapter(replies: [plan, bad, good, patch, answer])
        var options = MartyLoop.Options()
        options.followUp = "What if the wheel had twice as many teeth?"
        let out = tempOut()
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try MartyLoop(model: model, out: out, options: options).run(question: "How does a gear reduction work?")

        XCTAssertEqual(r["accepted"] as? Bool, true)
        let attempts = try XCTUnwrap(r["attempts"] as? [[String: Any]])
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0]["reason"] as? String, "component.param.range.wheelTeeth")
        XCTAssertEqual(attempts[1]["ok"] as? Bool, true)
        // The repair prompt carries the exact engine reason.
        XCTAssertTrue(model.prompts[2].user.contains("`component.param.range.wheelTeeth`"), model.prompts[2].user)
        // Unknown ids from the plan are dropped, not explained.
        XCTAssertEqual((r["plan"] as? [String: Any])?["dropped"] as? [String], ["wormGear"])
        XCTAssertTrue(model.prompts[1].system.contains("\"spurPair\""))

        let f = try XCTUnwrap(r["followUp"] as? [String: Any])
        XCTAssertEqual(f["changed"] as? Bool, true)
        let ratios = try XCTUnwrap((f["after"] as? [String: Any])?["ratios"] as? [String: Double])
        XCTAssertTrue(ratios.values.contains { abs(abs($0) - 12.0 / 72.0) < 1e-9 }, "\(ratios)")
        XCTAssertEqual(f["answer"] as? String, answer)
        // The answer prompt sees the engine's solved numbers after the change.
        XCTAssertTrue(model.prompts[4].user.contains("after the change"))

        let calls = try XCTUnwrap(r["calls"] as? [[String: Any]])
        XCTAssertEqual(calls.map { $0["phase"] as? String ?? "" }, ["plan", "author", "repair", "followup", "answer"])
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("receipt.json").path))
        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("lesson.json").path))
        for c in calls {
            let u = try XCTUnwrap((c["user"] as? [String: Any])?["file"] as? String)
            XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent(u).path), u)
        }
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathComponent("receipt.json"))) as? [String: Any])
        XCTAssertEqual(receipt["format"] as? String, MartyLoop.receiptFormat)
        XCTAssertEqual((receipt["engine"] as? [String: Any])?["revision"] as? String, MartyPin.engineRevision)
        let ctx = try XCTUnwrap(receipt["contextBytes"] as? [String: Int])
        XCTAssertLessThan(try XCTUnwrap(ctx["plan"]), 9000, "plan context grew: \(ctx)")
        XCTAssertLessThan(try XCTUnwrap(ctx["author"]), 12000, "author context grew: \(ctx)")
    }

    func testLoopStopsAfterTheRepairLimit() throws {
        let plan = #"{"components": [], "primitives": []}"#
        let model = ScriptedAdapter(replies: [plan, "not json", "still not", #"{"document": {"v": 1}}"#])
        var options = MartyLoop.Options()
        options.repairs = 2
        let out = tempOut()
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try MartyLoop(model: model, out: out, options: options).run(question: "q")
        XCTAssertEqual(r["accepted"] as? Bool, false)
        let attempts = try XCTUnwrap(r["attempts"] as? [[String: Any]])
        XCTAssertEqual(attempts.count, 3)
        XCTAssertEqual(attempts[0]["reason"] as? String, "json")
        XCTAssertNotNil(attempts[2]["reason"] as? String)
        XCTAssertNil(r["followUp"])
    }

    func testOutputDirectoryMustBeNew() throws {
        let out = tempOut()
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertThrowsError(try MartyLoop(model: ScriptedAdapter(replies: []), out: out, options: .init()))
    }

    func testClaudeAdapterRefusesOddModelIds() {
        XCTAssertThrowsError(try ClaudeCLIAdapter(model: "haiku; rm -rf /", executable: URL(fileURLWithPath: "/usr/bin/true")))
        XCTAssertNoThrow(try ClaudeCLIAdapter(model: "claude-haiku-5-5", executable: URL(fileURLWithPath: "/usr/bin/true")))
    }

    func testDevSetIsTheRegisteredFile() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let (qs, sha) = try Bench.load(root.appendingPathComponent("bench/dev-v1/questions.json"))
        XCTAssertEqual(sha, "81ba1f737484374defe94a4108dbf9194c4c3559954e468b459f7b75adc9e433")
        XCTAssertEqual(qs.count, 50)
        XCTAssertEqual(qs.filter { $0.scope == "in" }.count, 40)
        XCTAssertTrue(qs.allSatisfy { $0.followUp != nil })
    }

    func testBenchRunsEachQuestionWithAFreshModel() throws {
        let dir = tempOut()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("q.json")
        try Data(#"{"questions": [{"id": "S1", "prompt": "Show a gear reduction.", "scope": "in"}, {"id": "S2", "prompt": "Show a worm gear.", "scope": "out"}]}"#.utf8).write(to: file)
        let plan = #"{"components": ["spurPair"], "primitives": []}"#
        let good = #"{"document": \#(Self.spurReduction)}"#
        var made = 0
        let s = try Bench.run(file: file, ids: nil, makeModel: { made += 1; return ScriptedAdapter(replies: [plan, good]) },
                              out: dir.appendingPathComponent("run"), options: .init(), followUps: true)
        XCTAssertEqual(made, 2)
        let totals = try XCTUnwrap(s["totals"] as? [String: Any])
        XCTAssertEqual(totals["accepted"] as? Int, 2)
        XCTAssertEqual(totals["inScopeAccepted"] as? Int, 1)
        XCTAssertEqual(totals["firstTry"] as? Int, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("run/summary.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("run/S2/receipt.json").path))
        XCTAssertThrowsError(try Bench.run(file: file, ids: ["NOPE"], makeModel: { ScriptedAdapter(replies: []) },
                                           out: dir.appendingPathComponent("run2"), options: .init(), followUps: false))
    }

    /// A what-if patch that changes only words is refused; the model repairs it with a real change.
    func testTextOnlyFollowUpPatchIsRefused() throws {
        let plan = #"{"components": ["spurPair"], "primitives": []}"#
        let good = #"{"document": \#(Self.spurReduction)}"#
        let textOnly = #"{"patch": {"title": "Wheel held", "steps": [{"say": "Now the wheel is held still."}]}}"#
        let real = #"{"patch": {"parts": {"pair": {"with": {"pinionTeeth": 12, "wheelTeeth": 48}}}}}"#
        let model = ScriptedAdapter(replies: [plan, good, textOnly, real, "The wheel turns 12/48 = 1/4 turn."])
        var options = MartyLoop.Options()
        options.followUp = "What if the wheel had 48 teeth?"
        let out = tempOut()
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try MartyLoop(model: model, out: out, options: options).run(question: "q")
        let f = try XCTUnwrap(r["followUp"] as? [String: Any])
        let attempts = try XCTUnwrap(f["attempts"] as? [[String: Any]])
        XCTAssertEqual(attempts.first?["reason"] as? String, "followup.textOnly")
        XCTAssertEqual(f["changed"] as? Bool, true)
        XCTAssertEqual(f["ratiosChanged"] as? Bool, true)
        XCTAssertTrue(model.prompts[3].user.contains("changes only text"))
        XCTAssertTrue(model.prompts[4].user.contains("wheelTeeth"), "the answer prompt shows the accepted change")
    }

    func testEmptyFollowUpIsSkipped() throws {
        let plan = #"{"components": [], "primitives": []}"#
        let model = ScriptedAdapter(replies: [plan, #"{"document": \#(Self.spurReduction)}"#])
        var options = MartyLoop.Options()
        options.followUp = "  "
        let out = tempOut()
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try MartyLoop(model: model, out: out, options: options).run(question: "q")
        XCTAssertNil(r["followUp"])
        XCTAssertEqual(model.prompts.count, 2)
    }
}
