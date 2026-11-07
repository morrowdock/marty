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

    func testWithIsMergedIntoTheInstance() throws {
        let base = #"{"parts":[{"id":"stage","use":"planetaryStage","with":{"sunTeeth":30,"planetTeeth":18}}]}"#
        let merged = try XCTUnwrap(MartyLoop.mergingWith(["parts": ["stage": ["with": ["planets": 4, "planetTeeth": NSNull()]]]], base: base) as? [String: Any])
        let with = try XCTUnwrap(((merged["parts"] as? [String: Any])?["stage"] as? [String: Any])?["with"] as? [String: Any])
        XCTAssertEqual(with["sunTeeth"] as? Int, 30, "a parameter the patch did not name stays")
        XCTAssertEqual(with["planets"] as? Int, 4)
        XCTAssertNil(with["planetTeeth"], "null removes a parameter")
        // A patch that swaps the component keeps only its own with values.
        let swap = try XCTUnwrap(MartyLoop.mergingWith(["parts": ["stage": ["use": "otherStage", "with": ["a": 1]]]], base: base) as? [String: Any])
        XCTAssertEqual(MartyJSON.data(((swap["parts"] as? [String: Any])?["stage"] as? [String: Any])?["with"] ?? [:]), MartyJSON.data(["a": 1]))
        // Not a use entry, or no with: unchanged.
        let other: [String: Any] = ["parts": ["gear": ["material": "brass"]]]
        XCTAssertEqual(MartyJSON.data(MartyLoop.mergingWith(other, base: base)), MartyJSON.data(other))
    }

    func testComponentRefusalNamesTheComponent() throws {
        let plan = #"{"components": [], "primitives": []}"#
        let bad = #"{"document": \#(Self.spurReduction), "components": [{"v": 1, "kind": "component"}]}"#
        let model = ScriptedAdapter(replies: [plan, bad, #"{"document": \#(Self.spurReduction)}"#])
        let out = tempOut()
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try MartyLoop(model: model, out: out, options: .init()).run(question: "q")
        let attempts = try XCTUnwrap(r["attempts"] as? [[String: Any]])
        XCTAssertEqual(attempts.first?["component"] as? Int, 0)
        XCTAssertTrue(model.prompts[2].user.contains("on part `components[0]"), model.prompts[2].user)
        XCTAssertEqual(r["accepted"] as? Bool, true)
    }

    /// A render that fails is recorded in the receipt; the checked lesson still stands.
    func testRenderFailureIsRecorded() throws {
        var o = MartyLoop.Options()
        o.render = true
        let out = tempOut()
        defer { try? FileManager.default.removeItem(at: out) }
        let model = ScriptedAdapter(replies: [#"{"components": []}"#, #"{"document": \#(Self.spurReduction)}"#])
        let loop = try MartyLoop(model: model, out: out, options: o)
        // A file where the render directory must go makes the render fail before any GPU work.
        try Data("x".utf8).write(to: out.appendingPathComponent("render"))
        let r = try loop.run(question: "q")
        XCTAssertEqual(r["accepted"] as? Bool, true)
        XCTAssertEqual((r["render"] as? [String: Any])?["ok"] as? Bool, false)
        XCTAssertNotNil((r["render"] as? [String: Any])?["error"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("lesson.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("receipt.json").path))
    }

    func testBadOptionsAreRefusedBeforeAnyModelCall() throws {
        var o = MartyLoop.Options()
        o.size = "foo"
        let model = ScriptedAdapter(replies: [])
        XCTAssertThrowsError(try MartyLoop(model: model, out: tempOut(), options: o))
        XCTAssertTrue(model.prompts.isEmpty)
    }

    func testBenchKeepsGoingAfterAFailedQuestion() throws {
        let dir = tempOut()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("q.json")
        try Data(#"{"questions": [{"id": "A", "prompt": "one"}, {"id": "B", "prompt": "two"}]}"#.utf8).write(to: file)
        var n = 0
        let s = try Bench.run(file: file, ids: nil, makeModel: {
            n += 1
            if n == 1 { throw AdapterError(reason: "adapter.claude.missing", detail: "test") }
            return ScriptedAdapter(replies: [#"{"components": []}"#, #"{"document": \#(Self.spurReduction)}"#])
        }, out: dir.appendingPathComponent("run"), options: .init(), followUps: false)
        let runs = try XCTUnwrap(s["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.count, 2)
        XCTAssertNotNil(runs[0]["error"])
        XCTAssertEqual(runs[0]["reason"] as? String, "adapter.claude.missing")
        XCTAssertEqual((s["totals"] as? [String: Any])?["errors"] as? Int, 1)

        // A model call that fails inside the run (here the scripted adapter runs dry) is an error row too.
        let s2 = try Bench.run(file: file, ids: ["A"], makeModel: { ScriptedAdapter(replies: [#"{"components": []}"#]) },
                               out: dir.appendingPathComponent("run3"), options: .init(), followUps: false)
        let row = try XCTUnwrap((s2["runs"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["reason"] as? String, "adapter.scripted.empty")
        XCTAssertNotNil(row["error"])
        let t2 = try XCTUnwrap(s2["totals"] as? [String: Any])
        XCTAssertEqual(t2["errors"] as? Int, 1)
        XCTAssertEqual(t2["inScope"] as? Int, 0, "an error row is not a model result")
        XCTAssertEqual(runs[1]["accepted"] as? Bool, true)
        XCTAssertThrowsError(try Bench.run(file: file, ids: ["A", "A"], makeModel: { ScriptedAdapter(replies: []) },
                                           out: dir.appendingPathComponent("run2"), options: .init(), followUps: false))
    }

    /// Every hint key is a refusal reason that the pinned engine source really contains.
    func testHintKeysAreEngineReasons() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent(".build/checkouts/martygraphics/Sources/MartyGraphics/Solid")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        try XCTSkipIf(files.isEmpty, "engine checkout not found at \(dir.path)")
        let source = try files.filter { $0.hasSuffix(".swift") }.map { try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }.joined()
        for key in MartyPrompts.hintKeys {
            // The full reason as a string literal (a prefix like "ref.unknown.\\(id)" also starts this way).
            XCTAssertTrue(source.contains("\"\(key)"), "hint key \(key) is not a reason literal in the engine source")
        }
    }
}

/// The CLI adapter's process handling, with small fake executables in place of `claude`.
final class ClaudeAdapterProcessTests: XCTestCase {
    func fake(_ script: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("marty-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let u = dir.appendingPathComponent("claude")
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: u)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        return u
    }

    func testReplyAndMinimalEnvironment() throws {
        setenv("ANTHROPIC_API_KEY", "must-not-reach-the-child", 1)
        defer { unsetenv("ANTHROPIC_API_KEY") }
        let exe = try fake(#"cat >/dev/null; printf '{"result":"key=%s","is_error":false,"usage":{"input_tokens":3}}' "${ANTHROPIC_API_KEY:-none}""#)
        let r = try ClaudeCLIAdapter(model: "claude-haiku-5-5", executable: exe, timeout: 30).reply(system: "s", user: "u")
        XCTAssertEqual(r.text, "key=none")
        XCTAssertEqual((r.meta["usage"] as? [String: Any])?["input_tokens"] as? Int, 3)
    }

    func testTimeoutKillsAHungChild() throws {
        let exe = try fake("trap '' TERM; sleep 60")
        let t0 = Date()
        XCTAssertThrowsError(try ClaudeCLIAdapter(model: "m", executable: exe, timeout: 1).reply(system: "s", user: "u")) {
            XCTAssertEqual(($0 as? AdapterError)?.reason, "adapter.timeout")
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 20)
    }

    func testChildThatExitsWithoutReadingIsAnError() throws {
        let exe = try fake("exit 3")
        let big = String(repeating: "x", count: 1 << 20)
        XCTAssertThrowsError(try ClaudeCLIAdapter(model: "m", executable: exe, timeout: 30).reply(system: "s", user: big)) {
            XCTAssertEqual(($0 as? AdapterError)?.reason, "adapter.output")
        }
    }
}
