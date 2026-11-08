// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
import MartyGraphics
import MartyEngine
@testable import MartyLoop

@MainActor
final class MartyLoopTests: XCTestCase {
    func tempOut() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("marty-loop-tests-\(UUID().uuidString)", isDirectory: true)
    }

    func testPromptExamplesAreAccepted() throws {
        let r = try MartyEngine(outputRoot: nil).check(document: MartyExamples.formatExample, ref: nil, components: [], strict: true)
        XCTAssertEqual(r["ok"] as? Bool, true, "\(r["reason"] ?? "")")
        XCTAssertEqual((r["warnings"] as? [Any])?.count, 0, "\(r["warnings"] ?? "")")
        XCTAssertEqual(r["version"] as? Int, 2)
        XCTAssertTrue((r["steps"] as? [String] ?? []).contains { $0.contains("makes 1 turn") }, "the placeholder is filled by the engine")
    }

    /// A gear reduction document, as a model might write it (test data only; not a prompt example).
    static let spurReduction = #"{"v":1,"kind":"assembly","title":"Spur gear reduction","units":"mm","parts":[{"id":"pair","use":"spurPair","with":{"pinionTeeth":12,"wheelTeeth":36}}],"steps":[{"say":"A small pinion drives a larger wheel.","camera":"hero"},{"say":"Input: the pinion (12 teeth) turns once.","highlight":["pair.pinion"],"spin":1},{"say":"The wheel (36 teeth) turns 12/36 = 1/3 of a turn, the other way.","highlight":["pair.wheel"],"spin":1}]}"#

    /// The prompts stay small: measured with the real compact catalog and the real format example (bytes printed in the
    /// test log). The v1 eval harness sent about 25,600 bytes of engine docs in every call.
    func testPromptSizes() throws {
        let catalog = MartyJSON.string(try MartyEngine(outputRoot: nil).catalog(compact: true, components: []))
        let plan = MartyPrompts.planSystem(catalog: catalog).utf8.count
        let author = MartyPrompts.authorSystem(parts: "", example: MartyExamples.formatExample).utf8.count
        print("prompt bytes: plan \(plan), author without parts \(author)")
        XCTAssertLessThan(plan, 12000)
        XCTAssertLessThan(author, 12000)
    }

    /// The format example shows the explainer tools (section, ghost, a gravity force, an unchecked given number) and the
    /// engine accepts it in strict mode with no warnings.
    func testFormatExampleShowsTheExplainerTools() throws {
        let r = try MartyEngine(outputRoot: nil).check(document: MartyExamples.formatExample, ref: nil, components: [], strict: true)
        XCTAssertEqual(r["ok"] as? Bool, true, "\(r["reason"] ?? "") \(r["part"] ?? "")")
        let claims = ((r["legend"] as? [String: Any])?["claims"] as? [[String: Any]]) ?? []
        XCTAssertTrue(claims.contains { $0["id"] as? String == "aW" && $0["tier"] as? String == "solved" }, "gravity arrow is Solved: \(claims)")
        XCTAssertTrue(claims.contains { $0["id"] as? String == "lRated" && $0["tier"] as? String == "described" }, "given number is Not checked")
        XCTAssertNotNil(r["sectionTriangles"])
    }

    /// The explainer example: strict, no warnings; its typed number is Given (noted), its table shows an engine fact.
    func testExplainerExampleIsAccepted() throws {
        let r = try MartyEngine(outputRoot: nil).check(document: MartyExamples.explainerExample, ref: nil, components: [], strict: true)
        XCTAssertEqual(r["ok"] as? Bool, true, "\(r["reason"] ?? "") \(r["location"] ?? "")")
        XCTAssertEqual(r["kind"] as? String, "explainer")
        XCTAssertTrue(((r["legend"] as? [String: Any])?["text"] as? String ?? "").contains("Given"), "\(r["legend"] ?? "")")
        XCTAssertEqual((r["warnings"] as? [Any])?.count, 0, "\(r["warnings"] ?? "")")
        XCTAssertNotNil(r["facts"], "Marty copies the 3D facts for the loop")
        XCTAssertEqual((r["steps"] as? [String])?.count, 2)
        let plan = MartyPrompts.authorSystem(parts: "", example: MartyExamples.formatExample, explainer: MartyExamples.explainerExample).utf8.count
        print("prompt bytes: author with the explainer form, without parts \(plan)")
        XCTAssertLessThan(plan, 14500)
    }

    /// The plan chooses the explainer form: the author prompt gets the explainer section; the accepted explainer makes a
    /// lesson of kind explainer; the follow-up is answered without a patch (explainers have no patch format).
    func testExplainerFormEndToEnd() throws {
        let plan = #"{"form": "explainer", "components": ["shaftWithBearing"], "primitives": []}"#
        let doc = #"{"document": \#(MartyExamples.explainerExample)}"#
        let model = ScriptedAdapter(replies: [plan, doc, #"{"document": null}"#, "Nothing needs to change."])
        var options = MartyLoop.Options()
        options.followUp = "What if the shaft were longer?"
        let out = tempOut()
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try MartyLoop(model: model, out: out, options: options).run(question: "q")
        XCTAssertEqual(r["accepted"] as? Bool, true, "\(r["attempts"] ?? "")")
        XCTAssertGreaterThan(try XCTUnwrap((r["final"] as? [String: Any])?["triangles"] as? Int), 0, "the explainer's 3D triangles")
        XCTAssertTrue(model.prompts[1].system.contains("Explainer form"))
        XCTAssertTrue(model.prompts[1].system.contains("noted explainer table"), "the role allows noted table data")
        let f = try XCTUnwrap(r["followUp"] as? [String: Any])
        XCTAssertEqual(f["modelled"] as? Bool, true, "no change needed")
        XCTAssertEqual(f["answer"] as? String, "Nothing needs to change.")
        XCTAssertEqual(model.prompts.count, 4, "plan, author, follow-up, answer")
        XCTAssertTrue(model.prompts[2].system.contains("WHOLE changed explainer"))
        let lesson = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathComponent("lesson.json"))) as? [String: Any])
        XCTAssertEqual(lesson["kind"] as? String, "explainer")
        // The solid form keeps the small author prompt.
        let solid = ScriptedAdapter(replies: [#"{"components": []}"#, #"{"document": \#(Self.spurReduction)}"#])
        let out2 = tempOut()
        defer { try? FileManager.default.removeItem(at: out2) }
        _ = try MartyLoop(model: solid, out: out2, options: .init()).run(question: "q")
        XCTAssertFalse(solid.prompts[1].system.contains("Explainer form"))
    }

    /// An explainer follow-up sends the whole changed explainer: a model change is accepted; a change of words only is
    /// refused (followup.textOnly) and the model may then reply {"document": null}.
    func testExplainerFollowUpByDocument() throws {
        let plan = #"{"form": "explainer", "components": ["shaftWithBearing"], "primitives": []}"#
        let doc = #"{"document": \#(MartyExamples.explainerExample)}"#
        let changed = MartyExamples.explainerExample.replacingOccurrences(of: #""radius":6"#, with: #""radius":8"#)
        let words = MartyExamples.explainerExample.replacingOccurrences(of: "Cut open: the lower", with: "Cut open now: the lower")
        XCTAssertNotEqual(changed, MartyExamples.explainerExample)
        XCTAssertNotEqual(words, MartyExamples.explainerExample)
        func run(_ followReplies: [String]) throws -> (ScriptedAdapter, [String: Any]) {
            let model = ScriptedAdapter(replies: [plan, doc] + followReplies)
            var options = MartyLoop.Options()
            options.followUp = "What if the shaft were thicker?"
            let out = tempOut()
            defer { try? FileManager.default.removeItem(at: out) }
            let r = try MartyLoop(model: model, out: out, options: options).run(question: "q")
            return (model, try XCTUnwrap(r["followUp"] as? [String: Any]))
        }
        let (mOK, ok) = try run([#"{"document": \#(changed)}"#, "A thicker shaft."])
        XCTAssertEqual(ok["changed"] as? Bool, true, "\(ok["attempts"] ?? "")")
        XCTAssertEqual(ok["modelled"] as? Bool, true)
        XCTAssertTrue(mOK.prompts[3].user.contains(#""radius":8"#), "the answer prompt shows the accepted change: \(mOK.prompts[3].user)")
        // A table edit in a beat's ops is a model change; a board text item edit alone is words only.
        let table = MartyExamples.explainerExample.replacingOccurrences(of: #"["Rated rpm",3000]"#, with: #"["Rated rpm",3500]"#)
        XCTAssertNotEqual(table, MartyExamples.explainerExample)
        let (mTable, tableEdit) = try run([#"{"document": \#(table)}"#, "The rated speed is higher."])
        XCTAssertEqual(tableEdit["changed"] as? Bool, true, "\(tableEdit["attempts"] ?? "")")
        // The answer gets the changed values, before and after.
        XCTAssertTrue(mTable.prompts[3].user.contains("3000") && mTable.prompts[3].user.contains("3500"), mTable.prompts[3].user)
        // The answer gets the given figures of the accepted explainer, with their source.
        XCTAssertTrue(mTable.prompts[3].user.contains("- Rated rpm 3500 — maker's data sheet, 2024, claimed (given)"), mTable.prompts[3].user)
        let summary = MartyLoop.changeSummary(from: ["board": ["params": ["angle": 10]]], to: ["board": ["params": ["angle": 30]]])
        XCTAssertTrue(summary.contains("10") && summary.contains("30") && summary.contains("board"), summary)
        // A gravity arrow is checked again by the engine: no schematic-direction line.
        XCTAssertEqual(ok["forceArrowsMoved"] as? [String], [])
        XCTAssertFalse(mOK.prompts[3].user.contains("Force arrows the change moved"))
        let caption = MartyExamples.explainerExample.replacingOccurrences(of: #""text":"Key figures""#, with: #""text":"Figures""#)
        XCTAssertNotEqual(caption, MartyExamples.explainerExample)
        let (_, captionEdit) = try run([#"{"document": \#(caption)}"#, #"{"document": null}"#, "No change."])
        XCTAssertEqual((captionEdit["attempts"] as? [[String: Any]])?.first?["reason"] as? String, "followup.textOnly")
        // Only an explicit null is "no change"; another type is repaired. The document must stay an explainer.
        let (_, notObject) = try run([#"{"document": false}"#, #"{"document": null}"#, "No change."])
        XCTAssertEqual((notObject["attempts"] as? [[String: Any]])?.first?["reason"] as? String, "json")
        let (_, kind) = try run([#"{"document": \#(Self.spurReduction)}"#, #"{"document": null}"#, "No change."])
        XCTAssertEqual((kind["attempts"] as? [[String: Any]])?.first?["reason"] as? String, "followup.kind")
        let (m, text) = try run([#"{"document": \#(words)}"#, #"{"document": null}"#, "No change."])
        XCTAssertEqual((text["attempts"] as? [[String: Any]])?.first?["reason"] as? String, "followup.textOnly")
        XCTAssertTrue(m.prompts[3].user.contains("Only the words changed"))
    }

    /// Words only give the same model content: a caption-only beat, an added text item, a text or label set, a
    /// title or camera op, arrow text. A table cell, a part or an arrow end does not.
    func testExplainerModelContentIgnoresWords() throws {
        let base = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(MartyExamples.explainerExample.utf8)) as? [String: Any])
        func edited(_ f: (inout [String: Any]) -> Void) -> [String: Any] { var d = base; f(&d); return d }
        func beats(_ d: [String: Any]) -> [[String: Any]] { d["beats"] as? [[String: Any]] ?? [] }
        let same = MartyLoop.modelContent(base)
        let wordsOnly: [[String: Any]] = [
            edited { d in d["beats"] = beats(d) + [["say": "A new caption."]] },
            edited { d in d["beats"] = beats(d) + [["say": "A new caption.", "ops": [Any]()]] },
            edited { d in d["beats"] = beats(d) + [["say": "Note.", "ops": [["op": "add", "item": ["id": "n", "k": "text", "at": [1, 1], "text": "Note"]],
                                                                            ["op": "set", "id": "n", "key": "text", "value": "Note 2"],
                                                                            ["op": "set", "id": "cap", "key": "text", "value": "Figures"],
                                                                            ["op": "title", "title": "New"], ["op": "camera", "camera": [Any]()]]]] },
            edited { d in
                var solid = d["solid"] as! [String: Any], ann = solid["annotations"] as! [String: Any]
                var arrows = ann["arrows"] as! [[String: Any]]; arrows[0]["text"] = "Its weight"
                ann["arrows"] = arrows; solid["annotations"] = ann; d["solid"] = solid
            },
            // A label on the table, in its add payload, and a board title.
            edited { d in
                var b = beats(d), ops = b[0]["ops"] as! [[String: Any]], item = ops[0]["item"] as! [String: Any]
                item["label"] = "Rated figures"; ops[0]["item"] = item; b[0]["ops"] = ops; d["beats"] = b
                var board = d["board"] as! [String: Any]; board["title"] = "Figures"; d["board"] = board
            }]
        for (n, d) in wordsOnly.enumerated() { XCTAssertEqual(MartyLoop.modelContent(d), same, "case \(n)") }
        let modelChanges: [[String: Any]] = [
            edited { d in d["beats"] = beats(d) + [["say": "Gone.", "ops": [["op": "remove", "id": "t"]]]] },
            edited { d in d["beats"] = beats(d) + [["say": "Faster.", "ops": [["op": "params", "params": ["speed": 2]]]]] },
            edited { d in d["beats"] = beats(d) + [["say": "New.", "ops": [["op": "set", "id": "t", "key": "cells", "value": [["A", 1]]]]]] },
            edited { d in var board = d["board"] as! [String: Any]; board["params"] = ["angle": 30]; d["board"] = board },
            edited { d in
                var solid = d["solid"] as! [String: Any], ann = solid["annotations"] as! [String: Any]
                var arrows = ann["arrows"] as! [[String: Any]]; arrows[0]["to"] = ["world": [0, 0, -80]]
                ann["arrows"] = arrows; solid["annotations"] = ann; d["solid"] = solid
            }]
        for (n, d) in modelChanges.enumerated() { XCTAssertNotEqual(MartyLoop.modelContent(d), same, "case \(n)") }
    }

    /// Force arrows a change may move: an end on a moved part or on a part hung below it (part, mixed or "on" anchors),
    /// not an arrow with only world ends, never a gravity arrow; every force arrow when params or joints changed.
    func testMovedForceArrows() {
        let parts: [[String: Any]] = [["id": "pilot", "use": "mannequin"], ["id": "jet", "parent": "pilot.rightHand"],
                                      ["id": "nozzle", "parent": "jet"], ["id": "base"]]
        let annotations: [String: Any] = ["arrows": [
            ["id": "aT", "meaning": "force", "from": ["part": "nozzle", "offset": [0, 0, -10]], "to": ["part": "nozzle", "offset": [0, 0, -90]]],
            ["id": "aMix", "meaning": "force", "from": ["world": [0, 0, 0]], "to": "jet"],
            ["id": "aWorld", "meaning": "force", "from": ["world": [0, 0, 0]], "to": ["world": [0, 0, 50]]],
            ["id": "aBase", "meaning": "force", "from": "base", "to": ["part": "base", "offset": [0, 0, 9]]],
            ["id": "aW", "meaning": "force", "cause": "gravity", "from": "nozzle", "to": ["part": "nozzle", "offset": [0, 0, -50]]],
            ["id": "aFlow", "meaning": "flow", "from": "nozzle", "to": "base"]]]
        XCTAssertEqual(MartyLoop.movedForceArrows(annotations: annotations, parts: parts, moved: ["pilot"], all: false), ["aT", "aMix"])
        XCTAssertEqual(MartyLoop.movedForceArrows(annotations: annotations, parts: parts, moved: ["base"], all: false), ["aBase"])
        // An inner-part edit of the mannequin moves its whole instance: the jet hung on pilot.rightHand too.
        XCTAssertEqual(MartyLoop.movedForceArrows(annotations: annotations, parts: parts, moved: ["pilot.upperArmR"], all: false), ["aT", "aMix"])
        XCTAssertEqual(MartyLoop.movedForceArrows(annotations: annotations, parts: parts, moved: [], all: true), ["aT", "aMix", "aWorld", "aBase"])
        XCTAssertEqual(MartyLoop.movedForceArrows(annotations: annotations, parts: parts, moved: [], all: false, changedArrows: ["aWorld"]), ["aWorld"])
        let line = MartyPrompts.answerUser(followUp: "q", before: "{}", after: "{}", movedForceArrows: ["aT"])
        XCTAssertTrue(line.contains("Force arrows the change moved (their direction is schematic, not checked): aT."))
        XCTAssertFalse(MartyPrompts.answerUser(followUp: "q", before: "{}", after: "{}").contains("Force arrows"))
    }

    /// The guide's people and compressor patterns are true engine rules: worn parts hang on mannequin anchors, a force
    /// arrow starts outside the body, and the compressor default fits.
    func testGuidePeopleAndCompressorPatterns() throws {
        let doc: [String: Any] = ["v": 2, "kind": "assembly", "title": "A worn unit", "units": "mm", "parts": [
            ["id": "pilot", "use": "mannequin", "with": ["leftShoulder": 30, "rightShoulder": 50]],
            ["id": "jet", "name": "Arm unit (schematic)", "parent": "pilot.rightHand", "at": [-85, -62, 0],
             "shape": ["shaft": ["radius": 50, "length": 300, "z0": -80]]],
            ["id": "pack", "name": "Back unit (schematic)", "parent": "pilot.back", "at": [0, 60, 0],
             "shape": ["shaft": ["radius": 60, "length": 300, "z0": -150]]],
            ["id": "comp", "use": "centrifugalCompressor", "with": ["diameter": 80], "at": [600, 0, 900]]],
            "annotations": ["arrows": [["id": "aW", "meaning": "force", "cause": "gravity",
                                         "from": ["part": "pilot.body", "offset": [0, -260, -400]],
                                         "to": ["part": "pilot.body", "offset": [0, -260, -700]], "text": "Weight"],
                                        ["id": "aJet", "meaning": "force", "from": ["part": "jet", "offset": [0, 0, -120]],
                                         "to": ["part": "jet", "offset": [0, 0, -400]], "text": "Thrust (schematic)"]]],
            "steps": [["say": "A schematic pilot wears two units.", "annotate": ["aW", "aJet"]],
                      ["say": "The compressor wheel turns.", "highlight": ["comp.input"], "focus": ["comp.input"], "annotate": []]]]
        let r = try MartyEngine(outputRoot: nil).check(document: doc, ref: nil, components: [], strict: true)
        XCTAssertEqual(r["ok"] as? Bool, true, "\(r["reason"] ?? "") \(r["part"] ?? "")")
    }

    /// A question about how something flies needs thrust in "given": one more plan request when it is missing,
    /// recorded in the receipt; other questions get none.
    func testPlanAsksForThrustOnFlightQuestions() throws {
        let noThrust = #"{"components": ["spurPair"], "primitives": [], "given": ["weight 30 kg (maker)"]}"#
        let withThrust = #"{"components": ["spurPair"], "primitives": [], "given": ["thrust about 150 kgf (estimate)"]}"#
        let doc = #"{"document": \#(Self.spurReduction)}"#
        let model = ScriptedAdapter(replies: [noThrust, withThrust, doc])
        let out = tempOut()
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try MartyLoop(model: model, out: out, options: .init()).run(question: "How does a jet suit fly?")
        XCTAssertTrue(model.prompts[1].user.contains("has no thrust figure"), model.prompts[1].user)
        let lint = try XCTUnwrap((r["plan"] as? [String: Any])?["lint"] as? [String: Any])
        XCTAssertEqual(lint["reason"] as? String, "plan.given.thrust")
        XCTAssertEqual(lint["fixed"] as? Bool, true)
        XCTAssertTrue(model.prompts[2].user.contains("150 kgf"), "the author gets the fixed plan")
        XCTAssertTrue(MartyLoop.asksHowItFlies("How does a helicopter hover?"))
        XCTAssertTrue(MartyLoop.asksHowItFlies("How does a jet suit lift a person?"))
        XCTAssertFalse(MartyLoop.asksHowItFlies("How does a hydraulic lift work?"))
        XCTAssertFalse(MartyLoop.asksHowItFlies("How does a gear reduction work?"))
        let calls = try XCTUnwrap(r["calls"] as? [[String: Any]])
        XCTAssertTrue(calls.contains { $0["phase"] as? String == "plan" && $0["attempt"] as? Int == 2
            && ($0["outcome"] as? [String: Any])?["ok"] as? Bool == true })
        // Only "given" is taken from the reply, and only when it names thrust; a partial, bad or failed reply keeps
        // the original plan.
        func lintRun(_ second: [String]) throws -> (ScriptedAdapter, [String: Any]) {
            let m = ScriptedAdapter(replies: [noThrust] + second)
            let o = tempOut()
            defer { try? FileManager.default.removeItem(at: o) }
            return (m, try MartyLoop(model: m, out: o, options: .init()).run(question: "How does a drone fly?"))
        }
        for second in [[#"{"given": []}"#, doc], ["not json", doc], ["{}", doc], []] {
            let (m, rr) = try lintRun(second)
            let p = try XCTUnwrap(rr["plan"] as? [String: Any])
            XCTAssertEqual((p["lint"] as? [String: Any])?["fixed"] as? Bool, false, "\(second)")
            XCTAssertEqual((p["reply"] as? [String: Any])?["given"] as? [String], ["weight 30 kg (maker)"], "\(second)")
            XCTAssertEqual(p["chosen"] as? [String], ["spurPair"], "\(second)")
            if second.isEmpty { XCTAssertEqual(m.prompts.count, 3, "plan, failed lint call, then the author call (which fails too)") }
        }
        let (_, partial) = try lintRun([#"{"given": ["thrust about 150 kgf (estimate)"]}"#, doc])
        let pp = try XCTUnwrap((partial["plan"] as? [String: Any])?["reply"] as? [String: Any])
        XCTAssertEqual(pp["given"] as? [String], ["thrust about 150 kgf (estimate)"])
        XCTAssertEqual(pp["components"] as? [String], ["spurPair"], "the rest of the plan stays")
        let other = ScriptedAdapter(replies: [noThrust, doc])
        let out2 = tempOut()
        defer { try? FileManager.default.removeItem(at: out2) }
        let r2 = try MartyLoop(model: other, out: out2, options: .init()).run(question: "How does a gear reduction work?")
        XCTAssertNil((r2["plan"] as? [String: Any])?["lint"])
        XCTAssertEqual(other.prompts.count, 2)
    }

    /// A follow-up answer that compares shares with no figure and no hedge gets one rewrite request.
    func testAnswerComparativeLint() throws {
        let src = [#"{"labels": [{"text": "Back unit", "unchecked": "maker: 100 kgf"}]}"#]
        XCTAssertEqual(MartyLoop.unsupportedComparatives("The back engine gives most of the lift. The arms steer.", sources: src),
                       ["The back engine gives most of the lift"])
        XCTAssertEqual(MartyLoop.unsupportedComparatives("The back engine gives about a third of the lift.", sources: src), [])
        XCTAssertEqual(MartyLoop.unsupportedComparatives("In this schematic most of the lift comes from the arms.", sources: src), [])
        XCTAssertEqual(MartyLoop.unsupportedComparatives("The back unit gives 100 kgf, most of the lift.", sources: src), [])
        XCTAssertEqual(MartyLoop.unsupportedComparatives("The back unit gives 400 kgf, most of the lift.", sources: src).count, 1)
        // Decimals stay whole; promised phrases are covered; only evidence counts (no raw JSON).
        XCTAssertEqual(MartyLoop.unsupportedComparatives("The main unit supplies 1.5 kgf, most of the lift.", sources: ["Main 1.5 kgf — maker (given)"]), [])
        XCTAssertEqual(MartyLoop.unsupportedComparatives("The main unit supplies 5 kgf, most of the lift.", sources: ["Main 1.5 kgf — maker (given)"]).count, 1)
        XCTAssertEqual(MartyLoop.unsupportedComparatives("Most of the lift comes from 2 rear engines.", sources: MartyLoop.numberLeaves(["v": 1])).count, 1)
        XCTAssertEqual(MartyLoop.unsupportedComparatives("The back unit provides more than half the lift.", sources: []).count, 1)
        XCTAssertEqual(MartyLoop.unsupportedComparatives("All of its thrust comes from the back unit.", sources: []).count, 1)
        XCTAssertEqual(MartyLoop.unsupportedComparatives("The arms steer the suit. The back unit holds it up.", sources: []), [])
        XCTAssertEqual(MartyLoop.numberLeaves(["a": [3000, 1.5, true], "id": "u2"]).sorted(), ["1.5", "3000"])
        XCTAssertEqual(MartyLoop.numberLeaves([0.0000001, 1e20, 9007199254740993 as Int64, 3000.0]), ["0.0000001", "100000000000000000000", "9007199254740993", "3000"])
        XCTAssertEqual(MartyLoop.unsupportedComparatives("Most of it is 1 unit.", sources: MartyLoop.numberLeaves([0.0000001])).count, 1)
        // A table set in a later beat is listed too, marked with its beat.
        let doc: [String: Any] = ["notes": ["t": ["basis": "maker"]], "board": ["items": [Any]()], "beats": [
            ["ops": [["op": "add", "item": ["id": "t", "k": "table", "header": true, "cells": [["Item", "Value"], ["Rated rpm", 3000]]]]]],
            ["ops": [["op": "set", "id": "t", "key": "cells", "value": [["Item", "Value"], ["Rated rpm", 3500]]]]]]]
        XCTAssertEqual(MartyLoop.givenFigures(doc), ["Rated rpm 3000 — maker (given)", "Rated rpm 3500 — maker (given) (from beat 2)"])
        // Header changes replay in order, in both directions.
        func headerDoc(_ start: Bool, _ ops: [[String: Any]]) -> [String: Any] {
            ["notes": ["t": ["basis": "maker"]], "board": ["items": [["id": "t", "k": "table", "header": start, "cells": [["A", 1]]]]],
             "beats": [["ops": ops]]]
        }
        XCTAssertEqual(MartyLoop.givenFigures(headerDoc(true, [["op": "set", "id": "t", "key": "header", "value": false],
                                                               ["op": "set", "id": "t", "key": "cells", "value": [["Rated rpm", 3500]]]])),
                       ["Rated rpm 3500 — maker (given) (from beat 1)"])
        XCTAssertEqual(MartyLoop.givenFigures(headerDoc(false, [["op": "set", "id": "t", "key": "header", "value": true],
                                                                ["op": "set", "id": "t", "key": "cells", "value": [["Item", "Value"], ["B", 2]]]])),
                       ["A 1 — maker (given)", "B 2 — maker (given) (from beat 1)"])
        // Floats keep their short text, with exponents written out; matching ignores trailing zeros.
        XCTAssertEqual(MartyLoop.numberLeaves([579.988, 0.1, 1.5e-7, 1e200]).prefix(3), ["579.988", "0.1", "0.00000015"])
        XCTAssertEqual(MartyLoop.numberLeaves([1e200]).first?.count, 201)
        XCTAssertEqual(MartyLoop.unsupportedComparatives("Most of it, 579.988 kgf, is from the back.", sources: MartyLoop.numberLeaves([579.988])), [])
        XCTAssertEqual(MartyLoop.unsupportedComparatives("Most of it, 3000.0 rpm, is the rotor.", sources: ["3000 rpm"]), [])
        // The refused answer gets no given figures; a modelled one does.
        XCTAssertFalse(MartyPrompts.answerUser(followUp: "q", before: "{}", after: nil, refused: "x", given: ["T 1 kgf — m"]).contains("Given figures"))
        XCTAssertTrue(MartyPrompts.answerUser(followUp: "q", before: "{}", after: "{}", given: ["T 1 kgf — m"]).contains("- T 1 kgf — m"))
        let plan = #"{"components": ["spurPair"], "primitives": []}"#
        let good = #"{"document": \#(Self.spurReduction)}"#
        let patch = #"{"patch": {"parts": {"pair": {"with": {"pinionTeeth": 12, "wheelTeeth": 72}}}}}"#
        let model = ScriptedAdapter(replies: [plan, good, patch, "The wheel does most of the work now.", "The wheel now turns more slowly."])
        var options = MartyLoop.Options()
        options.followUp = "What if the wheel had more teeth?"
        let out = tempOut()
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try MartyLoop(model: model, out: out, options: options).run(question: "How does a gear reduction work?")
        let f = try XCTUnwrap(r["followUp"] as? [String: Any])
        XCTAssertEqual(f["answer"] as? String, "The wheel now turns more slowly.")
        let lint = try XCTUnwrap(f["answerLint"] as? [String: Any])
        XCTAssertEqual(lint["reason"] as? String, "answer.comparative")
        XCTAssertEqual(lint["fixed"] as? Bool, true)
        XCTAssertTrue(model.prompts[4].user.contains("compare sizes or shares"))
        // A rewrite that fails in the adapter keeps the first answer, with fixed false.
        let failing = ScriptedAdapter(replies: [plan, good, patch, "The wheel does most of the work now."])
        let out2 = tempOut()
        defer { try? FileManager.default.removeItem(at: out2) }
        let f2 = try XCTUnwrap(try MartyLoop(model: failing, out: out2, options: options).run(question: "How does a gear reduction work?")["followUp"] as? [String: Any])
        XCTAssertEqual(f2["answer"] as? String, "The wheel does most of the work now.")
        XCTAssertEqual(f2["ok"] as? Bool, true)
        XCTAssertEqual((f2["answerLint"] as? [String: Any])?["fixed"] as? Bool, false)
    }

    /// A visibility refusal reaches the repair prompt in words (the engine's visibility detail), and the attempt keeps
    /// the detail; strict refuses a defined label that no step lists.
    func testVisibilityDetailInRepairs() throws {
        func doc(_ steps: [[String: Any]], labels n: Int = 13) -> [String: Any] {
            ["v": 2, "kind": "assembly", "title": "Labels", "units": "mm",
             "parts": [["id": "box", "shape": ["box": ["size": [40, 40, 40]]]]],
             "annotations": ["labels": (1...n).map { ["id": "l\($0)", "at": ["world": [0, 0, 30 + $0 * 5]], "text": "Label"] }],
             "steps": steps]
        }
        let all = (1...13).map { "l\($0)" }
        let tooMany = doc([["say": "All labels.", "annotate": all]])
        let good = doc([["say": "Some labels.", "annotate": Array(all.prefix(7))], ["say": "The rest.", "annotate": Array(all.dropFirst(7))]])
        let plan = #"{"components": [], "primitives": ["box"]}"#
        func reply(_ d: [String: Any]) -> String { #"{"document": "# + MartyJSON.string(d) + "}" }
        let model = ScriptedAdapter(replies: [plan, reply(tooMany), reply(good)])
        let out = tempOut()
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try MartyLoop(model: model, out: out, options: .init()).run(question: "q")
        XCTAssertEqual(r["accepted"] as? Bool, true, "\(r["attempts"] ?? "")")
        let first = try XCTUnwrap((r["attempts"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["reason"] as? String, "step.annotate.count")
        XCTAssertEqual((first["visibility"] as? [String: Any])?["cause"] as? String, "step")
        XCTAssertTrue(model.prompts[2].user.contains(#"Step 1's "annotate" lists 13; the limit is 12"#), model.prompts[2].user)
        // No annotate list anywhere: every step shows all 13.
        let engine = MartyEngine(outputRoot: nil)
        let plain = try engine.check(document: doc([["say": "All."]]), ref: nil, components: [], strict: true)
        XCTAssertEqual(plain["reason"] as? String, "annotations.visible")
        let line = MartyPrompts.visibilityLine(try XCTUnwrap(plain["visibility"] as? [String: Any]))
        XCTAssertTrue(line?.contains("Give every step an \"annotate\" list") == true, line ?? "nil")
        // An explainer: the limit is per beat, and the beat's list is named.
        var ex = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(MartyExamples.explainerExample.utf8)) as? [String: Any])
        var solid = try XCTUnwrap(ex["solid"] as? [String: Any])
        solid["annotations"] = ["labels": (1...13).map { ["id": "l\($0)", "at": ["world": [0, 0, 30 + $0 * 5]], "text": "Label"] }]
        ex["solid"] = solid
        ex["beats"] = [["say": "All labels.", "view": ["annotate": all]]]
        let exr = try engine.check(document: ex, ref: nil, components: [], strict: true)
        XCTAssertEqual(exr["reason"] as? String, "view.annotate.count", "\(exr)")
        let exLine = MartyPrompts.visibilityLine(try XCTUnwrap(exr["visibility"] as? [String: Any], "\(exr)"))
        XCTAssertTrue(exLine?.hasPrefix(#"Beat 1's "view"."annotate" lists 13"#) == true, exLine ?? "nil")
        // A defined label no step lists is refused in strict mode.
        let unused = try engine.check(document: doc([["say": "Some.", "annotate": ["l1"]]], labels: 2), ref: nil, components: [], strict: true)
        XCTAssertTrue((unused["reason"] as? String ?? "").hasPrefix("annotation.unused"), "\(unused["reason"] ?? "")")
    }

    /// Marty's lint of an accepted document: more than 5 texts in a step (an arrow without text does not count), and a
    /// share or comparison in a say or label with no figure, {fact} or hedge. The examples are clean.
    func testDocumentLint() throws {
        XCTAssertEqual(MartyLoop.documentLint(try JSONSerialization.jsonObject(with: Data(MartyExamples.formatExample.utf8))), [])
        XCTAssertEqual(MartyLoop.documentLint(try JSONSerialization.jsonObject(with: Data(MartyExamples.explainerExample.utf8))), [])
        func doc(labels: Int, arrows: Int, say: String) -> [String: Any] {
            ["v": 2, "kind": "assembly", "title": "Lint", "units": "mm",
             "parts": [["id": "box", "shape": ["box": ["size": [40, 40, 40]]]]],
             "annotations": ["labels": (0..<labels).map { ["id": "l\($0)", "at": ["world": [0, 0, 30 + $0 * 5]], "text": "Label"] },
                             "arrows": (0..<arrows).map { ["id": "a\($0)", "meaning": "force", "from": "box", "to": ["world": [0, 0, -50 - $0]]] }
                                 + [["id": "aT", "meaning": "force", "from": "box", "to": ["world": [0, 9, -60]], "text": "Thrust"]]],
             "steps": [["say": say, "annotate": (0..<labels).map { "l\($0)" } + (0..<arrows).map { "a\($0)" } + ["aT"]]]]
        }
        XCTAssertEqual(MartyLoop.documentLint(doc(labels: 4, arrows: 5, say: "The box.")), [], "5 texts; untexted arrows do not count")
        let six = MartyLoop.documentLint(doc(labels: 5, arrows: 0, say: "The box."))
        XCTAssertEqual(six.count, 1); XCTAssertTrue(six[0].hasPrefix("Step 1 shows 6 texts"), six[0])
        let most = MartyLoop.documentLint(doc(labels: 1, arrows: 0, say: "The back engine carries most of the load."))
        XCTAssertEqual(most.count, 1); XCTAssertTrue(most[0].contains("most of the load"), most[0])
        XCTAssertEqual(MartyLoop.documentLint(doc(labels: 1, arrows: 0, say: "The wheel turns {pair.wheel.speed|frac}, more than none.")), [])
        XCTAssertEqual(MartyLoop.documentLint(doc(labels: 1, arrows: 0, say: "In this schematic the back unit gives most of the lift.")), [])
        // The loop asks for one repair; with none left, the engine-accepted document stands with its lint recorded.
        let plan = #"{"components": [], "primitives": ["box"]}"#
        func reply(_ d: [String: Any]) -> String { #"{"document": "# + MartyJSON.string(d) + "}" }
        let bad = doc(labels: 5, arrows: 0, say: "The box."), good = doc(labels: 4, arrows: 0, say: "The box.")
        let model = ScriptedAdapter(replies: [plan, reply(bad), reply(good)])
        let out = tempOut()
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try MartyLoop(model: model, out: out, options: .init()).run(question: "q")
        XCTAssertEqual(r["accepted"] as? Bool, true)
        XCTAssertNil(r["lint"])
        let first = try XCTUnwrap((r["attempts"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["reason"] as? String, "marty.lint"); XCTAssertEqual(first["engineOk"] as? Bool, true)
        XCTAssertTrue(model.prompts[2].user.contains("Marty's checks found these problems"), model.prompts[2].user)
        let fallback = ScriptedAdapter(replies: [plan, reply(bad), "not json", "not json", "not json"])
        let out2 = tempOut()
        defer { try? FileManager.default.removeItem(at: out2) }
        let r2 = try MartyLoop(model: fallback, out: out2, options: .init()).run(question: "q")
        XCTAssertEqual(r2["accepted"] as? Bool, true, "the engine-accepted document stands")
        XCTAssertEqual((r2["lint"] as? [String])?.count, 1)
        XCTAssertEqual((r2["final"] as? [String: Any])?["title"] as? String, "Lint")
        XCTAssertEqual(r2["lintAttempt"] as? Int, 0)
        // One lint repair at most: a second lint-dirty accepted reply ends the loop; the one with fewer findings stands.
        let worse = doc(labels: 6, arrows: 0, say: "The back engine carries most of the load.")
        let repeated = ScriptedAdapter(replies: [plan, reply(bad), reply(worse), reply(good)])
        let out3 = tempOut()
        defer { try? FileManager.default.removeItem(at: out3) }
        let r3 = try MartyLoop(model: repeated, out: out3, options: .init()).run(question: "q")
        XCTAssertEqual(repeated.prompts.count, 3, "plan, author, one lint repair")
        XCTAssertEqual((r3["attempts"] as? [[String: Any]])?.map { $0["reason"] as? String }, ["marty.lint", "marty.lint"])
        XCTAssertEqual((r3["lint"] as? [String])?.count, 1, "the better document (one finding) stands")
        XCTAssertEqual(r3["lintAttempt"] as? Int, 0)
        var once = MartyLoop.Options(); once.repairs = 1
        let short = ScriptedAdapter(replies: [plan, reply(worse), reply(bad)])
        let out4 = tempOut()
        defer { try? FileManager.default.removeItem(at: out4) }
        let r4 = try MartyLoop(model: short, out: out4, options: once).run(question: "q")
        XCTAssertEqual((r4["lint"] as? [String])?.count, 1, "the later, better document stands")
        XCTAssertEqual(r4["lintAttempt"] as? Int, 1)
        // A tie goes to the later document, and an engine refusal between keeps the fallback; the final document is
        // the selected one.
        var badB = doc(labels: 5, arrows: 0, say: "The box."); badB["title"] = "Lint B"
        let tie = ScriptedAdapter(replies: [plan, reply(bad), #"{"document": {"v": 2}}"#, reply(badB)])
        let out5 = tempOut()
        defer { try? FileManager.default.removeItem(at: out5) }
        let r5 = try MartyLoop(model: tie, out: out5, options: .init()).run(question: "q")
        XCTAssertEqual((r5["attempts"] as? [[String: Any]])?.map { $0["reason"] as? String }.first, "marty.lint")
        XCTAssertNotEqual((r5["attempts"] as? [[String: Any]])?[1]["reason"] as? String, "marty.lint", "the engine refused attempt 2")
        XCTAssertEqual(r5["lintAttempt"] as? Int, 2)
        XCTAssertEqual((r5["final"] as? [String: Any])?["title"] as? String, "Lint B")
        // Given figures: no merged range (a span of years is fine); a source needs a year unless "reported" or an
        // "assumed example".
        XCTAssertTrue(MartyLoop.hasMergedRange("144–155 kgf"))
        XCTAssertTrue(MartyLoop.hasMergedRange("144 to 155 kgf"))
        XCTAssertFalse(MartyLoop.hasMergedRange("classic suit (2020–2022)"))
        XCTAssertFalse(MartyLoop.hasMergedRange("144 kgf"))
        XCTAssertFalse(MartyLoop.hasMergedRange("Airbus A320-200 seats"))
        XCTAssertFalse(MartyLoop.hasMergedRange("data sheet, 2024-05-01"))
        XCTAssertFalse(MartyLoop.hasMergedRange("data sheet, 2024-05"))
        XCTAssertFalse(MartyLoop.hasMergedRange("classic suit 2020–2022."))
        XCTAssertFalse(MartyLoop.hasMergedRange("a 2-stroke engine"))
        XCTAssertTrue(MartyLoop.hasMergedRange("144-155kgf"))
        XCTAssertTrue(MartyLoop.hasMergedRange("1.5–2.5 kN."))
        // Unchecked table notes are checked too.
        let table: [String: Any] = ["kind": "explainer", "notes": ["t": ["unchecked": "maker"]], "solid": [String: Any](),
            "board": ["items": [["id": "t", "k": "table", "header": true, "cells": [["Item", "Value"], ["Thrust", "144–155 kgf"], ["Turns", "{a.b}"]]]]],
            "beats": [["say": "A table."]]]
        let tableLint = MartyLoop.documentLint(table)
        XCTAssertEqual(tableLint.count, 2, "\(tableLint)")
        XCTAssertTrue(tableLint.contains { $0.contains("merges two figures") })
        // givenFigures for an unchecked table: its tier, the beat suffix of a later set, and the 12-line cap.
        let rows = (0..<14).map { ["R\($0)", $0] as [Any] }
        let un: [String: Any] = ["notes": ["t": ["unchecked": "reported"]], "board": ["items": [["id": "t", "k": "table", "cells": [["A", 1]]]]],
                                 "beats": [["ops": [["op": "set", "id": "t", "key": "cells", "value": rows]]]]]
        let figs = MartyLoop.givenFigures(un)
        XCTAssertEqual(figs.count, 12)
        XCTAssertEqual(figs[0], "A 1 — reported (not checked)")
        XCTAssertEqual(figs[1], "R0 0 — reported (not checked) (from beat 1)")
        func given(_ text: String, _ source: String) -> [String: Any] {
            var g = doc(labels: 1, arrows: 0, say: "The box.")
            g["annotations"] = ["labels": [["id": "l0", "at": ["world": [0, 0, 30]], "text": text, "unchecked": source]]]
            g["steps"] = [["say": "The box.", "annotate": ["l0"]]]
            return g
        }
        XCTAssertEqual(MartyLoop.documentLint(given("Thrust 144 kgf", "maker, 2019, claimed")), [])
        XCTAssertEqual(MartyLoop.documentLint(given("Thrust 144 kgf", "reported")), [])
        XCTAssertEqual(MartyLoop.documentLint(given("Mass 100 kg", "assumed example")), [])
        XCTAssertEqual(MartyLoop.documentLint(given("Thrust 144 kgf", "maker")).count, 1)
        XCTAssertTrue(MartyLoop.documentLint(given("Thrust 144–155 kgf", "maker, 2019")).first?.contains("merges two figures") == true)
        // A repeated id shows once.
        var dup = doc(labels: 6, arrows: 0, say: "The box.")
        dup["steps"] = [["say": "The box.", "annotate": ["l0", "l0", "l0", "l0", "l0", "l0", "l1", "l2", "l3", "l4", "l5"]]]
        XCTAssertEqual(MartyLoop.documentLint(dup).first?.hasPrefix("Step 1 shows 6 texts"), true)
        dup["steps"] = [["say": "The box.", "annotate": ["l0", "l0", "l0", "l0", "l0", "l0"]], ["say": "More.", "annotate": ["l1", "l2", "l3", "l4", "l5"]]]
        XCTAssertEqual(MartyLoop.documentLint(dup), [])
        var ex = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(MartyExamples.explainerExample.utf8)) as? [String: Any])
        var solid = try XCTUnwrap(ex["solid"] as? [String: Any])
        solid["annotations"] = ["labels": (0..<6).map { ["id": "l\($0)", "at": ["world": [0, 0, 30 + $0 * 5]], "text": "Label"] }]
        ex["solid"] = solid
        ex["beats"] = [["say": "All.", "view": ["annotate": ["l0", "l0", "l1", "l2", "l3", "l4"]]], ["say": "Six.", "view": ["annotate": (0..<6).map { "l\($0)" }]]]
        XCTAssertEqual(MartyLoop.documentLint(ex).map { String($0.prefix(18)) }, ["Beat 2 shows 6 tex"])
    }

    /// The guide's engine pattern: a mannequin with five microTurbojets (one cut open) fits the part limit and is
    /// accepted in strict mode, highlighting casings; nine are over the limit, and the repair prompt states the
    /// engine's parts.resolved detail.
    func testMicroTurbojetPatternAndPartsLimit() throws {
        func doc(_ n: Int, studs: Int = 0) -> [String: Any] {
            let mounts = ["pilot.leftHand", "pilot.rightHand", "pilot.leftHand", "pilot.rightHand", "pilot.back"]
            var parts: [[String: Any]] = [["id": "pilot", "use": "mannequin", "with": ["leftShoulder": 30, "rightShoulder": 40]]]
            for i in 0..<n {
                parts.append(["id": "e\(i)", "use": "microTurbojet", "with": ["diameter": 110, "length": 280, "cutaway": i == 4 ? 1 : 0],
                              "parent": mounts[i % 5], "at": [i % 2 == 0 ? 80 : -80, 70 + 20 * i, 0], "rot": [1, 0, 0, 180]])
            }
            for k in 0..<studs {   // each a row of 12 (repeat holds 2 to 12)
                parts.append(["id": "stud\(k)", "name": "Stud (schematic)", "parent": "pilot.back", "at": [0, 10, 100 + 10 * k],
                              "shape": ["box": ["size": [5, 5, 5]]], "repeat": ["count": 12, "axis": [0, 1, 0]]])
            }
            return ["v": 2, "kind": "assembly", "title": "Five small jet engines", "units": "mm", "parts": parts,
                    "steps": [["say": "A schematic pilot wears small jet engines.", "highlight": (0..<min(n, 5)).map { "e\($0).casing" }],
                              ["say": "One engine is cut open.", "highlight": ["e4.casing"], "focus": ["e\(min(n, 5) - 1)"], "spin": 1]]]
        }
        let engine = MartyEngine(outputRoot: nil)
        let r = try engine.check(document: doc(5), ref: nil, components: [], strict: true)
        XCTAssertEqual(r["ok"] as? Bool, true, "\(r["reason"] ?? "") \(r["part"] ?? "")")
        // Components alone over 96 parts: parts.count (no detail at this pin); with repeat: parts.resolved with it.
        XCTAssertEqual(try engine.check(document: doc(9), ref: nil, components: [], strict: true)["reason"] as? String, "parts.count")
        let over = try engine.check(document: doc(5, studs: 3), ref: nil, components: [], strict: true)
        XCTAssertEqual(over["reason"] as? String, "parts.resolved")
        let line = try XCTUnwrap(MartyPrompts.limitLine(try XCTUnwrap(over["limit"] as? [String: Any], "\(over)")))
        XCTAssertTrue(line.hasPrefix("The model has ") && line.contains("the limit is 96") && line.contains("(microTurbojet, 11 parts)"), line)
        let plan = #"{"components": ["mannequin", "microTurbojet"], "primitives": []}"#
        func reply(_ d: [String: Any]) -> String { #"{"document": "# + MartyJSON.string(d) + "}" }
        let model = ScriptedAdapter(replies: [plan, reply(doc(5, studs: 3)), reply(doc(5))])
        let out = tempOut()
        defer { try? FileManager.default.removeItem(at: out) }
        let loop = try MartyLoop(model: model, out: out, options: .init()).run(question: "q")
        XCTAssertEqual((loop["attempts"] as? [[String: Any]])?.first?["reason"] as? String, "parts.resolved")
        XCTAssertNotNil((loop["attempts"] as? [[String: Any]])?.first?["limit"])
        XCTAssertTrue(model.prompts[2].user.contains("the limit is 96"), model.prompts[2].user)
    }

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
        XCTAssertLessThan(try XCTUnwrap(ctx["plan"]), 12000, "plan context grew: \(ctx)")
        XCTAssertLessThan(try XCTUnwrap(ctx["author"]), 13000, "author context grew: \(ctx)")
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

    /// Every patch refused: the learner still gets an answer, told plainly that the model cannot show the change.
    func testRefusedFollowUpStillAnswersHonestly() throws {
        let plan = #"{"components": ["spurPair"], "primitives": []}"#
        let good = #"{"document": \#(Self.spurReduction)}"#
        let bad = #"{"patch": {"parts": {"pair": {"with": {"wheelTeeth": 999}}}}}"#
        let model = ScriptedAdapter(replies: [plan, good, bad, bad, "This model cannot show that change."])
        var options = MartyLoop.Options()
        options.repairs = 1
        options.followUp = "What if the wheel had 999 teeth?"
        let out = tempOut()
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try MartyLoop(model: model, out: out, options: options).run(question: "q")
        let f = try XCTUnwrap(r["followUp"] as? [String: Any])
        XCTAssertEqual(f["modelled"] as? Bool, false)
        XCTAssertEqual(f["changed"] as? Bool, false)
        XCTAssertEqual(f["answer"] as? String, "This model cannot show that change.")
        XCTAssertTrue(model.prompts[4].user.contains("refused every change"), model.prompts[4].user)
        XCTAssertTrue(model.prompts[4].system.contains("do no arithmetic"), "the refused case has its own system prompt")
        XCTAssertTrue(model.prompts[4].user.contains("component.param.range.wheelTeeth"))
    }

    /// A refused patch, then an adapter failure: no answer call, ok false.
    func testRefusedThenAdapterFailureWritesNoAnswer() throws {
        let plan = #"{"components": ["spurPair"], "primitives": []}"#
        let good = #"{"document": \#(Self.spurReduction)}"#
        let bad = #"{"patch": {"parts": {"pair": {"with": {"wheelTeeth": 999}}}}}"#
        let model = ScriptedAdapter(replies: [plan, good, bad])
        var options = MartyLoop.Options()
        options.followUp = "What if the wheel had 999 teeth?"
        let out = tempOut()
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try MartyLoop(model: model, out: out, options: options).run(question: "q")
        let f = try XCTUnwrap(r["followUp"] as? [String: Any])
        XCTAssertEqual(f["ok"] as? Bool, false)
        XCTAssertNil(f["answer"])
        XCTAssertEqual(model.prompts.count, 4, "plan, author, two follow-up calls; no answer call")
    }

    /// Only text-only patches: the engine never saw a change, and the answer prompt says so.
    func testNoCheckedChangeIsWordedHonestly() throws {
        let plan = #"{"components": ["spurPair"], "primitives": []}"#
        let good = #"{"document": \#(Self.spurReduction)}"#
        let textOnly = #"{"patch": {"title": "Wheel held"}}"#
        let model = ScriptedAdapter(replies: [plan, good, textOnly, textOnly, "This model cannot show that."])
        var options = MartyLoop.Options()
        options.repairs = 1
        options.followUp = "What if the wheel were held?"
        let out = tempOut()
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try MartyLoop(model: model, out: out, options: options).run(question: "q")
        XCTAssertTrue(model.prompts[4].user.contains("No change could be checked"), model.prompts[4].user)
        XCTAssertTrue(model.prompts[4].system.contains("do no arithmetic"))
    }

    /// The compound-train pattern in the constraint.underdetermined hint, parsed from the hint text itself, is accepted
    /// by the engine (strict) and solves 1/9: the hint and the test cannot drift apart.
    func testCompoundTrainHintPatternIsTrue() throws {
        let hint = try XCTUnwrap(MartyPrompts.hint(for: "constraint.underdetermined"))
        func object(after marker: String) throws -> [String: Any] {
            let start = try XCTUnwrap(hint.range(of: marker)).lowerBound
            var depth = 0, end = start
            for i in hint[start...].indices {
                if hint[i] == "{" { depth += 1 } else if hint[i] == "}" { depth -= 1; if depth == 0 { end = i; break } }
            }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(hint[start...end].utf8)) as? [String: Any])
        }
        let s1 = try object(after: #"{"id": "s1""#), s2 = try object(after: #"{"id": "s2""#)
        let doc: [String: Any] = ["v": 2, "kind": "assembly", "title": "Two stages", "units": "mm", "parts": [s1, s2]]
        let r = try MartyEngine(outputRoot: nil).check(document: doc, ref: nil, components: [], strict: true)
        XCTAssertEqual(r["ok"] as? Bool, true, "\(r["reason"] ?? "") \(r["part"] ?? "")")
        let ratios = try XCTUnwrap(r["ratios"] as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(ratios["s2.wheel"]), 1.0 / 9.0, accuracy: 1e-9, "\(ratios)")
    }

    func testSpecificHintsWinOverGeneralOnes() {
        XCTAssertTrue(MartyPrompts.hint(for: "constraint.conflict.drive")?.contains("follow or crank drive") == true)
        XCTAssertTrue(MartyPrompts.hint(for: "constraint.conflict")?.contains("turns only with its parent") == true)
    }

    /// An engine refusal, then a bad reply: the answer prompt names the engine's reason, not Marty's json.
    func testRefusedAnswerShowsTheEngineReason() throws {
        let plan = #"{"components": ["spurPair"], "primitives": []}"#
        let good = #"{"document": \#(Self.spurReduction)}"#
        let bad = #"{"patch": {"parts": {"pair": {"with": {"wheelTeeth": 999}}}}}"#
        let model = ScriptedAdapter(replies: [plan, good, bad, "not json", "This model cannot show that."])
        var options = MartyLoop.Options()
        options.repairs = 1
        options.followUp = "What if the wheel had 999 teeth?"
        let out = tempOut()
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try MartyLoop(model: model, out: out, options: options).run(question: "q")
        XCTAssertTrue(model.prompts[4].user.contains("last reason: component.param.range.wheelTeeth"), model.prompts[4].user)
    }

    /// A typed number in a v2 caption: the repair prompt carries the engine's facts for that model.
    func testCaptionRefusalRepairGetsTheFacts() throws {
        let plan = #"{"components": ["spurPair"], "primitives": []}"#
        let typed = #"{"document": {"v": 2, "kind": "assembly", "title": "Pair", "units": "mm", "parts": [{"id": "pair", "use": "spurPair"}], "steps": [{"say": "The wheel has 36 teeth."}]}}"#
        let fixed = #"{"document": {"v": 2, "kind": "assembly", "title": "Pair", "units": "mm", "parts": [{"id": "pair", "use": "spurPair"}], "steps": [{"say": "The wheel has {pair.wheel.teeth} teeth."}]}}"#
        let model = ScriptedAdapter(replies: [plan, typed, fixed])
        let out = tempOut()
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try MartyLoop(model: model, out: out, options: .init()).run(question: "q")
        let attempts = try XCTUnwrap(r["attempts"] as? [[String: Any]])
        XCTAssertEqual(attempts.first?["reason"] as? String, "text.number.step.1")
        XCTAssertTrue(model.prompts[2].user.contains("pair.wheel.teeth: 36"), model.prompts[2].user)
        XCTAssertEqual(r["accepted"] as? Bool, true)
        XCTAssertEqual(((r["final"] as? [String: Any])?["steps"] as? [String])?.first, "The wheel has 36 teeth.")
        let lesson = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathComponent("lesson.json"))) as? [String: Any])
        XCTAssertEqual(lesson["version"] as? Int, 2)
    }

    /// Run one scripted session and return the model's prompts.
    func prompts(_ replies: [String], followUp: String? = nil, repairs: Int = 3) throws -> (ScriptedAdapter, [String: Any]) {
        let model = ScriptedAdapter(replies: replies)
        var options = MartyLoop.Options()
        options.followUp = followUp
        options.repairs = repairs
        let out = tempOut()
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try MartyLoop(model: model, out: out, options: options).run(question: "q")
        return (model, r)
    }
    static func pairDoc(title: String = "Pair", say: String, check: String? = nil, with: String = "") -> String {
        #"{"document": {"v": 2, "kind": "assembly", "title": "\#(title)", "units": "mm", "parts": [{"id": "pair", "use": "spurPair"\#(with)}], "steps": [{"say": "\#(say)"\#(check.map { ", \"check\": [\($0)]" } ?? "")}]}}"#
    }

    /// A false claim: the repair prompt has the engine's facts for the model.
    func testFalseClaimRepairGetsTheFacts() throws {
        let wrong = Self.pairDoc(say: "The wheel has {pair.wheel.teeth} teeth.", check: #"{"value": "pair.wheel.teeth", "eq": 40}"#)
        let right = Self.pairDoc(say: "The wheel has {pair.wheel.teeth} teeth.", check: #"{"value": "pair.wheel.teeth", "eq": 36}"#)
        let (m, r) = try prompts([#"{"components": []}"#, wrong, right])
        XCTAssertEqual((r["attempts"] as? [[String: Any]])?.first?["reason"] as? String, "check.failed.pair.wheel.teeth")
        XCTAssertTrue(m.prompts[2].user.contains("pair.wheel.teeth: 36"), m.prompts[2].user)
        XCTAssertEqual(r["accepted"] as? Bool, true)
    }

    /// A bad placeholder in the title: the facts still come (from a copy with a plain title and no steps).
    func testTitlePlaceholderRepairGetsTheFacts() throws {
        let bad = Self.pairDoc(title: "A pair with {nope.teeth} teeth", say: "A pinion drives a wheel.")
        let (m, r) = try prompts([#"{"components": []}"#, bad, Self.pairDoc(say: "A pinion drives a wheel.")])
        XCTAssertTrue(((r["attempts"] as? [[String: Any]])?.first?["reason"] as? String ?? "").hasPrefix("text."), "\(r["attempts"] ?? "")")
        XCTAssertTrue(m.prompts[2].user.contains("pair.wheel.teeth: 36"), m.prompts[2].user)
    }

    /// An expect mismatch is refused while parsing; the read-back comes from the same document without expect.
    func testExpectRefusalGetsTheReadBack() throws {
        let doc = #"{"document": {"v": 2, "kind": "assembly", "title": "Shaft", "units": "mm", "parts": [{"id": "s", "name": "Shaft", "shape": {"shaft": {"radius": 4, "length": 20}}, "joint": {"revolute": [0, 0, 1]}, "drive": {"input": 1}, "expect": {"axisWorld": [1, 0, 0]}}]}}"#
        let (m, r) = try prompts([#"{"components": []}"#, doc, #"{"document": \#(Self.spurReduction)}"#])
        XCTAssertEqual((r["attempts"] as? [[String: Any]])?.first?["reason"] as? String, "expect.axis.s")
        XCTAssertTrue(m.prompts[2].user.contains("Engine read-back"), m.prompts[2].user)
        XCTAssertTrue(m.prompts[2].user.contains("s: world centre"))
    }

    /// An expect mismatch plus a bad caption: the read-back still comes (captions are dropped from the copy too).
    func testExpectRefusalWithASecondErrorGetsTheReadBack() throws {
        let doc = #"{"document": {"v": 2, "kind": "assembly", "title": "Shaft", "units": "mm", "parts": [{"id": "s", "name": "Shaft", "shape": {"shaft": {"radius": 4, "length": 20}}, "joint": {"revolute": [0, 0, 1]}, "drive": {"input": 1}, "expect": {"axisWorld": [1, 0, 0]}}], "steps": [{"say": "It turns {nope.speed} times."}]}}"#
        let (m, r) = try prompts([#"{"components": []}"#, doc, #"{"document": \#(Self.spurReduction)}"#])
        XCTAssertEqual((r["attempts"] as? [[String: Any]])?.first?["reason"] as? String, "expect.axis.s")
        XCTAssertTrue(m.prompts[2].user.contains("s: world centre"), m.prompts[2].user)
    }

    /// An expect mismatch inside a use entry's set: the read-back still comes (from a copy without it).
    func testExpectInASetEntryGetsTheReadBack() throws {
        let doc = #"{"document": {"v": 2, "kind": "assembly", "title": "Shaft", "units": "mm", "parts": [{"id": "u", "use": "shaftWithBearing", "set": {"shaft": {"expect": {"axisWorld": [1, 0, 0]}}}}]}}"#
        let (m, r) = try prompts([#"{"components": []}"#, doc, #"{"document": \#(Self.spurReduction)}"#])
        let reason = (r["attempts"] as? [[String: Any]])?.first?["reason"] as? String ?? ""
        XCTAssertTrue(reason.hasPrefix("expect.axis"), reason)
        XCTAssertTrue(m.prompts[2].user.contains("Engine read-back"), m.prompts[2].user)
    }

    func testWithoutExpectStripsSetEntries() {
        let p = MartyLoop.withoutExpect(["id": "u", "use": "x", "expect": ["upWorld": [0, 0, 1]],
                                         "set": ["inner": ["expect": ["axisWorld": [1, 0, 0]], "material": "brass"]]])
        XCTAssertNil(p["expect"])
        XCTAssertNil(((p["set"] as? [String: Any])?["inner"] as? [String: Any])?["expect"])
        XCTAssertEqual(((p["set"] as? [String: Any])?["inner"] as? [String: Any])?["material"] as? String, "brass")
        XCTAssertEqual(p["id"] as? String, "u")
        XCTAssertEqual(p["use"] as? String, "x")
    }

    /// A what-if that makes a claim false: the follow-up repair has the facts of the changed model.
    func testFollowUpClaimRefusalGetsTheChangedFacts() throws {
        let base = Self.pairDoc(say: "The wheel has {pair.wheel.teeth} teeth.", check: #"{"value": "pair.wheel.teeth", "eq": 36}"#)
        let patch = #"{"patch": {"parts": {"pair": {"with": {"wheelTeeth": 48}}}}}"#
        let (m, r) = try prompts([#"{"components": []}"#, base, patch, #"{"patch": null}"#, "The wheel would have more teeth."],
                                 followUp: "What if the wheel had 48 teeth?")
        let f = try XCTUnwrap(r["followUp"] as? [String: Any])
        XCTAssertEqual((f["attempts"] as? [[String: Any]])?.first?["reason"] as? String, "check.failed.pair.wheel.teeth")
        XCTAssertTrue(m.prompts[3].user.contains("Facts the engine solved for the changed model"), m.prompts[3].user)
        XCTAssertTrue(m.prompts[3].user.contains("pair.wheel.teeth: 48"), m.prompts[3].user)
    }

    func testFactListsAreCapped() {
        var facts: [String: Any] = [:]
        for i in 0..<200 { facts["part\(i).teeth"] = ["text": "\(i)", "tier": "solved"] }
        let lines = MartyLoop.factLines(["facts": facts], limit: 80) ?? []
        XCTAssertEqual(lines.count, 81)
        XCTAssertEqual(lines.last, "(120 more)")
    }

    /// An idle joint is refused in strict mode, and the repair prompt carries the engine's read-back.
    func testIdleJointRepairGetsTheReadBack() throws {
        let plan = #"{"components": [], "primitives": []}"#
        let idle = #"{"document": {"v": 2, "kind": "assembly", "title": "Shaft", "units": "mm", "parts": [{"id": "s", "name": "Shaft", "shape": {"shaft": {"radius": 4, "length": 20}}, "joint": {"revolute": [0, 0, 1]}}]}}"#
        let model = ScriptedAdapter(replies: [plan, idle, #"{"document": \#(Self.spurReduction)}"#])
        let out = tempOut()
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try MartyLoop(model: model, out: out, options: .init()).run(question: "q")
        XCTAssertEqual((r["attempts"] as? [[String: Any]])?.first?["reason"] as? String, "joint.idle.s")
        XCTAssertTrue(model.prompts[2].user.contains("Engine read-back"), model.prompts[2].user)
        XCTAssertTrue(model.prompts[2].user.contains("s: world centre"), model.prompts[2].user)
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

    func testPlanAdapterFailureStopsTheRun() throws {
        let model = ScriptedAdapter(replies: [])
        let out = tempOut()
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try MartyLoop(model: model, out: out, options: .init()).run(question: "q")
        XCTAssertEqual(model.prompts.count, 2, "two plan attempts, then stop")
        XCTAssertEqual(r["adapterErrors"] as? [String], ["adapter.scripted.empty", "adapter.scripted.empty"])
        XCTAssertEqual(r["accepted"] as? Bool, false)
        XCTAssertEqual(MartyJSON.data(r["attempts"] ?? []), MartyJSON.data([["ok": false, "reason": "adapter"]]))
    }

    /// An adapter failure on the first plan call and a plan on the second: the run goes on (the model was reached).
    final class FlakyAdapter: ModelAdapter {
        let id = "flaky"
        var replies: [String?]
        init(_ r: [String?]) { replies = r }
        func reply(system: String, user: String) throws -> ModelReply {
            guard !replies.isEmpty, let t = replies.removeFirst() else { throw AdapterError(reason: "adapter.timeout", detail: "test") }
            return ModelReply(text: t, seconds: 0)
        }
    }

    func testMixedPlanFailures() throws {
        let doc = #"{"document": \#(Self.spurReduction)}"#
        // adapter failure, then a plan: continues and is accepted; the adapter error is still recorded.
        let out1 = tempOut(); defer { try? FileManager.default.removeItem(at: out1) }
        let r1 = try MartyLoop(model: FlakyAdapter([nil, #"{"components": []}"#, doc]), out: out1, options: .init()).run(question: "q")
        XCTAssertEqual(r1["accepted"] as? Bool, true)
        XCTAssertEqual(r1["adapterErrors"] as? [String], ["adapter.timeout"])
        // not JSON, then an adapter failure: no plan was received, so the run stops.
        let out2 = tempOut(); defer { try? FileManager.default.removeItem(at: out2) }
        let r2 = try MartyLoop(model: FlakyAdapter(["not json", nil, doc]), out: out2, options: .init()).run(question: "q")
        XCTAssertEqual(r2["accepted"] as? Bool, false)
        XCTAssertEqual(MartyJSON.data(r2["attempts"] ?? []), MartyJSON.data([["ok": false, "reason": "adapter"]]))
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

    /// Every hint key is a reason in the engine's own reason catalog (MGSolidReasons at the pin): the key itself, or the
    /// key followed by one slot value (a hint matches a reason by prefix, so `joint.idle` covers `joint.idle.<id>`).
    func testHintKeysAreEngineReasons() {
        for key in MartyPrompts.hintKeys {
            let candidates = [key, key + ".x", key + ".1", key + ".x.y", key + ".bogusKey"]
            XCTAssertTrue(candidates.contains { MGSolidReasons.lookup($0) != nil }, "hint key \(key) is not an engine reason")
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
