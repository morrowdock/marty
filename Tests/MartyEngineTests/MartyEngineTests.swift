// SPDX-License-Identifier: Apache-2.0
import Foundation
import Metal
import MartyGraphics
import XCTest
@testable import MartyEngine

@MainActor
final class MartyEngineTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func fixture(_ name: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent("Tests/Fixtures/\(name)"), encoding: .utf8)
    }

    func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testPinMatchesPackageResolved() throws {
        let resolved = try String(contentsOf: Self.root.appendingPathComponent("Package.resolved"), encoding: .utf8)
        XCTAssertTrue(resolved.contains(MartyPin.engineRevision), "Package.resolved must pin \(MartyPin.engineRevision)")
        let manifest = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(manifest.contains(MartyPin.engineRevision))
    }

    func testParsedBooleansStayBooleans() throws {
        let parsed = try JSONSerialization.jsonObject(with: Data(#"{"a":true,"b":[false,1,2.5],"c":{"d":false}}"#.utf8))
        XCTAssertEqual(MartyJSON.string(parsed), #"{"a":true,"b":[false,1,2.5],"c":{"d":false}}"#)
        XCTAssertEqual(MartyJSON.string(["x": Double.nan, "y": true]), #"{"x":null,"y":true}"#)
    }

    func testEngineExampleModelsAreAccepted() throws {
        let e = MartyEngine(outputRoot: nil)
        for name in ["planetary.json", "planetary-components.json", "slider-crank.json", "slider-crank-component.json", "propeller.json"] {
            let r = try e.check(document: try fixture(name), ref: nil, components: [])
            XCTAssertEqual(r["ok"] as? Bool, true, "\(name): \(r)")
            XCTAssertNotNil(r["ref"] as? String)
        }
        let p = try e.check(document: try fixture("planetary.json"), ref: nil, components: [])
        let ratios = try XCTUnwrap(p["ratios"] as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(ratios["carrier"]), 24.0 / 84.0, accuracy: 1e-9)
        XCTAssertEqual((p["checks"] as? [String: Any])?["gearsEngage"] as? Bool, true)
        XCTAssertEqual((p["steps"] as? [String])?.count, 5)
    }

    /// Marty's report equals `marty-solid check [--strict]` at the pinned commit, field by field, for every engine example
    /// model (the engine's own committed golden files).
    func testReportMatchesTheEngineCLI() throws {
        func same(_ a: Any?, _ b: Any?, _ path: String) {
            switch (a, b) {
            case let (x as [String: Any], y as [String: Any]):
                XCTAssertEqual(Set(x.keys), Set(y.keys), path)
                for k in x.keys { same(x[k], y[k], path + "." + k) }
            case let (x as [Any], y as [Any]):
                XCTAssertEqual(x.count, y.count, path)
                for (i, (p, q)) in zip(x, y).enumerated() { same(p, q, "\(path)[\(i)]") }
            case let (x as NSNumber, y as NSNumber):
                let xb = CFGetTypeID(x) == CFBooleanGetTypeID(), yb = CFGetTypeID(y) == CFBooleanGetTypeID()
                XCTAssertEqual(xb, yb, "\(path): boolean against number")
                XCTAssertEqual(x.doubleValue, y.doubleValue, accuracy: 1e-9 * max(1, abs(x.doubleValue)), path)
            default:
                XCTAssertEqual("\(a ?? "nil")", "\(b ?? "nil")", path)
            }
        }
        // The engine's own models and its committed CLI golden reports, in the resolved checkout at the pin.
        let engine = Self.root.appendingPathComponent(".build/checkouts/martygraphics/Examples/Solid3D")
        let models = engine.appendingPathComponent("Sources/MartySolid3D/Models")
        let goldens = engine.appendingPathComponent("Tests/MartySolidCLITests/Golden")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: models.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        try XCTSkipIf(names.isEmpty, "engine checkout not found at \(engine.path)")
        let e = MartyEngine(outputRoot: nil)
        var compared = 0
        for file in names {
            let name = String(file.dropLast(5))
            for strict in [false, true] {
                let g = goldens.appendingPathComponent("models-\(name).\(strict ? "strict" : "check").json")
                guard let data = try? Data(contentsOf: g) else { continue }
                var cli = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                let text = try String(contentsOf: models.appendingPathComponent(file), encoding: .utf8)
                var mine = try XCTUnwrap(try JSONSerialization.jsonObject(with: MartyJSON.data(try e.check(document: text, ref: nil, components: [], strict: strict))) as? [String: Any])
                // `file` describes different bytes (the CLI's file; Marty's canonical JSON). The goldens predate the fields
                // the engine's own golden test strips (`engine`, `partTiers`, `motionTiers`, the anchor fields
                // `anchorIssues`, `anchorUntested`, `anchor`, and the arrow fields `arrowIssues`, `arrow`); Marty must have
                // the first three.
                if mine["readBack"] != nil {
                    XCTAssertNotNil(mine["partTiers"] as? [Any], "\(name): partTiers")
                    XCTAssertNotNil(mine["motionTiers"] as? [Any], "\(name): motionTiers")
                }
                XCTAssertNotNil(mine["engine"] as? [String: Any], "\(name): engine")
                for k in ["file", "engine", "partTiers", "motionTiers", "anchorIssues", "anchorUntested", "anchor", "arrowIssues", "arrow"] {
                    cli.removeValue(forKey: k); mine.removeValue(forKey: k)
                }
                for k in ["ref", "partIds"] { mine.removeValue(forKey: k) }
                // The CLI leaves `part` out when there is none; Marty always has the key.
                if mine["part"] is NSNull, cli["part"] == nil { mine.removeValue(forKey: "part") }
                same(mine, cli, "\(name) strict=\(strict)")
                compared += 1
            }
        }
        XCTAssertGreaterThanOrEqual(compared, 12, "the engine ships golden reports for its example models")
    }

    /// Drives and constraints with object bodies name every missing required key and refuse an unknown key.
    func testDriveAndConstraintKeysMatchTheEngine() throws {
        let e = MartyEngine(outputRoot: nil)
        /// Applies `edit` to the first object stored under `key` anywhere in `value`.
        func mutate(_ value: Any, _ key: String, _ edit: (inout [String: Any]) -> Void, _ done: inout Bool) -> Any {
            if var o = value as? [String: Any] {
                if !done, var body = o[key] as? [String: Any] { edit(&body); o[key] = body; done = true; return o }
                for k in o.keys.sorted() { o[k] = mutate(o[k]!, key, edit, &done) }
                return o
            }
            if let a = value as? [Any] { return a.map { mutate($0, key, edit, &done) } }
            return value
        }
        let bodies: [(id: String, prefix: String)] = [("follow", "part.drive.follow"), ("crankSlider", "part.drive.crankSlider"),
                                                      ("crankRod", "part.drive.crankRod"), ("gearMesh", "constraint.gearMesh")]
        for (id, prefix) in bodies {
            let p = try XCTUnwrap(MartyPrimitive.all.first { $0.id == id })
            func reason(_ edit: (inout [String: Any]) -> Void) throws -> String {
                var done = false
                let doc = mutate(try object(p.example), id, edit, &done)
                XCTAssertTrue(done, id)
                return try e.check(document: doc, ref: nil, components: [])["reason"] as? String ?? "accepted"
            }
            for key in p.required {
                XCTAssertEqual(try reason { $0.removeValue(forKey: key) }, "\(prefix).missing.\(key)", id)
            }
            XCTAssertEqual(try reason { $0["bogusKey"] = 1 }, "\(prefix).unknown.bogusKey", id)
            for key in p.optional { XCTAssertNotEqual(try reason { $0[key] = "wrong type" }, "\(prefix).unknown.\(key)", id) }
        }
    }

    func testEveryPrimitiveExampleIsAccepted() throws {
        let e = MartyEngine(outputRoot: nil)
        for p in MartyPrimitive.all {
            // Strict as models are checked, and with no warnings at all: an example must not teach a lint.
            let r = try e.check(document: p.example, ref: nil, components: [], strict: true)
            XCTAssertEqual(r["ok"] as? Bool, true, "\(p.id): \(r["reason"] ?? "")")
            XCTAssertEqual((r["warnings"] as? [Any])?.count, 0, "\(p.id): \(r["warnings"] ?? "")")
        }
        XCTAssertEqual(Set(MartyPrimitive.all.map(\.id)).count, MartyPrimitive.all.count)
    }

    /// The shape key lists match the parser: a missing required key is named, an unknown key is refused,
    /// and every optional key is known (a wrong value gives a value reason, never `unknown`).
    func testShapeKeysMatchTheEngine() throws {
        let e = MartyEngine(outputRoot: nil)
        for p in MartyPrimitive.all where p.kind == .shape {
            func variant(_ edit: (inout [String: Any]) -> Void) throws -> String {
                var doc = try object(p.example)
                var parts = doc["parts"] as! [[String: Any]]
                var shape = parts[0]["shape"] as! [String: Any]
                var body = shape[p.id] as! [String: Any]
                edit(&body)
                shape[p.id] = body; parts[0]["shape"] = shape; doc["parts"] = parts
                let r = try e.check(document: doc, ref: nil, components: [])
                return r["reason"] as? String ?? "accepted"
            }
            for key in p.required {
                XCTAssertEqual(try variant { $0.removeValue(forKey: key) }, "part.\(p.id).missing.\(key)", p.id)
            }
            XCTAssertEqual(try variant { $0["bogusKey"] = 1 }, "part.\(p.id).unknown.bogusKey", p.id)
            for key in p.optional {
                let reason = try variant { $0[key] = "wrong type" }
                XCTAssertFalse(reason.contains(".unknown."), "\(p.id).\(key) is not known to the engine: \(reason)")
                XCTAssertNotEqual(reason, "accepted", "\(p.id).\(key) accepted a string")
            }
        }
    }

    func testRefusalsCarryTheEngineReason() throws {
        let e = MartyEngine(outputRoot: nil)
        var doc = try object(MartyPrimitive.all.first { $0.id == "gearMesh" }!.example)
        var parts = doc["parts"] as! [[String: Any]]
        parts[1]["at"] = [50, 0, 0]   // 2 mm too far for 12 + 36 teeth at module 2
        doc["parts"] = parts
        let r = try e.check(document: doc, ref: nil, components: [])
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertEqual(r["reason"] as? String, "constraint.gearMesh.distance")
        XCTAssertNotNil(r["ref"])

        XCTAssertEqual(try e.check(document: "{not json", ref: nil, components: [])["reason"] as? String, "json")
        XCTAssertEqual(try e.check(document: 42, ref: nil, components: [])["reason"] as? String, "json")
        let big = "{\"title\": \"" + String(repeating: "a", count: MGSolidLimits.bytes) + "\"}"
        XCTAssertEqual(try e.check(document: big, ref: nil, components: [])["reason"] as? String, "assembly.bytes")
    }

    /// v2 facts fill captions; strict refuses an idle joint that the plain profile only warns about.
    func testFactsTiersAndStrict() throws {
        let e = MartyEngine(outputRoot: nil)
        let v2: [String: Any] = ["v": 2, "kind": "assembly", "title": "Pair", "units": "mm",
                                 "parts": [["id": "g", "use": "spurPair", "with": ["wheelTeeth": 48]]],
                                 "steps": [["say": "The wheel turns {g.wheel.speed|abs|frac} of a turn.", "check": [["value": "g.wheel.speed", "lt": 0]]]]]
        let r = try e.check(document: v2, ref: nil, components: [], strict: true)
        XCTAssertEqual(r["ok"] as? Bool, true, "\(r["reason"] ?? "")")
        XCTAssertEqual((r["steps"] as? [String])?.first, "The wheel turns 1/4 of a turn.")
        XCTAssertEqual(((r["facts"] as? [String: Any])?["g.wheel.speed"] as? [String: Any])?["tier"] as? String, "solved")
        XCTAssertFalse((r["readBack"] as? [String] ?? []).isEmpty)
        // A typed number in a v2 caption is refused (rule N1).
        var typed = v2
        typed["steps"] = [["say": "The wheel turns 1/4 of a turn."]]
        XCTAssertEqual(try e.check(document: typed, ref: nil, components: [])["reason"] as? String, "text.number.step.1")
        // An idle joint: a warning in the plain profile, a refusal in strict.
        let idle: [String: Any] = ["v": 1, "kind": "assembly", "title": "Idle", "units": "mm",
                                   "parts": [["id": "s", "shape": ["shaft": ["radius": 4, "length": 20]], "joint": ["revolute": [0, 0, 1]]]]]
        let plain = try e.check(document: idle, ref: nil, components: [], strict: false)
        XCTAssertEqual(plain["ok"] as? Bool, true)
        XCTAssertEqual(((plain["warnings"] as? [[String: Any]])?.first)?["reason"] as? String, "joint.idle.s")
        let strict = try e.check(document: idle, ref: nil, components: [], strict: true)
        XCTAssertEqual(strict["ok"] as? Bool, false)
        XCTAssertEqual(strict["reason"] as? String, "joint.idle.s")
        XCTAssertEqual(strict["part"] as? String, "s")
    }

    func testDocumentArgumentErrors() throws {
        let e = MartyEngine(outputRoot: nil)
        XCTAssertThrowsError(try e.check(document: nil, ref: nil, components: [])) { XCTAssertEqual(($0 as? ToolError)?.reason, "args.document") }
        XCTAssertThrowsError(try e.check(document: "{}", ref: "sha256:00", components: [])) { XCTAssertEqual(($0 as? ToolError)?.reason, "args.document") }
        XCTAssertThrowsError(try e.check(document: nil, ref: "sha256:00", components: [])) { XCTAssertEqual(($0 as? ToolError)?.reason, "cache.miss") }
        XCTAssertThrowsError(try e.check(document: "{}", ref: nil, components: Array(repeating: "{}", count: 9))) {
            XCTAssertEqual(($0 as? ToolError)?.reason, "args.components.count")
        }
    }

    func testRefIgnoresFormattingAndReplaysTheSameReport() throws {
        let e = MartyEngine(outputRoot: nil)
        let text = try fixture("slider-crank-component.json")
        let a = try e.check(document: text, ref: nil, components: [])
        let b = try e.check(document: try object(text), ref: nil, components: [])
        XCTAssertEqual(MartyJSON.data(a), MartyJSON.data(b))
        let ref = try XCTUnwrap(a["ref"] as? String)
        XCTAssertTrue(ref.hasPrefix("sha256:") && ref.count == 71)
        XCTAssertEqual(MartyJSON.data(try e.check(document: nil, ref: ref, components: [])), MartyJSON.data(a))
        // A fresh engine gives the same bytes.
        XCTAssertEqual(MartyJSON.data(try MartyEngine(outputRoot: nil).check(document: text, ref: nil, components: [])), MartyJSON.data(a))
    }

    func testCacheIsBounded() throws {
        let e = MartyEngine(outputRoot: nil)
        let first = try XCTUnwrap(try e.check(document: #"{"title":"0"}"#, ref: nil, components: [])["ref"] as? String)
        for i in 1...MartyLimits.cachedDocuments { _ = try e.check(document: #"{"title":"\#(i)"}"#, ref: nil, components: []) }
        XCTAssertThrowsError(try e.check(document: nil, ref: first, components: []))
    }

    func testPatchWhatIf() throws {
        let e = MartyEngine(outputRoot: nil)
        let base = try e.check(document: try fixture("planetary-components.json"), ref: nil, components: [])
        let ref = try XCTUnwrap(base["ref"] as? String)
        let r = try e.patch(document: nil, ref: ref, patch: ["parts": ["stage": ["with": ["planets": 4]]]], components: [], returnDocument: true)
        XCTAssertEqual(r["ok"] as? Bool, true, "\(r)")
        XCTAssertEqual(r["baseRef"] as? String, ref)
        let newRef = try XCTUnwrap(r["ref"] as? String)
        XCTAssertNotEqual(newRef, ref)
        XCTAssertGreaterThan(try XCTUnwrap(r["parts"] as? Int), try XCTUnwrap(base["parts"] as? Int))
        // The patched document checks the same by ref and by value.
        let byRef = try e.check(document: nil, ref: newRef, components: [])
        let byValue = try MartyEngine(outputRoot: nil).check(document: try XCTUnwrap(r["document"]), ref: nil, components: [])
        XCTAssertEqual(byRef["ref"] as? String, newRef)
        XCTAssertEqual(byValue["ref"] as? String, newRef)
        XCTAssertEqual(MartyJSON.data(byRef), MartyJSON.data(byValue))

        let bad = try e.patch(document: nil, ref: ref, patch: ["colour": "red"], components: [], returnDocument: false)
        XCTAssertEqual(bad["reason"] as? String, "patch.unknown.colour")
        XCTAssertEqual(bad["stage"] as? String, "patch")
        let tooMany = try e.patch(document: nil, ref: ref, patch: ["parts": ["stage": ["with": ["planets": 40]]]], components: [], returnDocument: false)
        XCTAssertEqual(tooMany["ok"] as? Bool, false)
        XCTAssertNotNil(tooMany["reason"] as? String)
    }

    func testComponentCheckAndUse() throws {
        let e = MartyEngine(outputRoot: nil)
        guard case .object(var def) = try XCTUnwrap(MGSolidLibrary.builtIn["spurPair"]).source else { return XCTFail() }
        def["id"] = .string("myPair")
        let definition = MGJSON.object(def).any
        let r = try e.componentCheck(definition: definition, with: ["wheelTeeth": 48], components: [])
        XCTAssertEqual(r["ok"] as? Bool, true, "\(r)")
        XCTAssertEqual((r["use"] as? [String: Any])?["use"] as? String, "myPair")
        let ratios = try XCTUnwrap((r["instance"] as? [String: Any])?["ratios"] as? [String: Double])
        XCTAssertTrue(ratios.values.contains { abs(abs($0) - 12.0 / 48.0) < 1e-9 }, "\(ratios)")

        let doc: [String: Any] = ["v": 1, "kind": "assembly", "title": "Uses a new component", "units": "mm",
                                  "parts": [["id": "a", "use": "myPair", "with": ["wheelTeeth": 48]]]]
        XCTAssertEqual(try e.check(document: doc, ref: nil, components: [definition])["ok"] as? Bool, true)
        XCTAssertEqual(try e.check(document: doc, ref: nil, components: [])["ok"] as? Bool, false)
        let dup = try e.componentCheck(definition: MGSolidLibrary.builtIn["spurPair"]!.source.any, with: [:], components: [])
        XCTAssertEqual(dup["ok"] as? Bool, false)
        let range = try e.componentCheck(definition: definition, with: ["wheelTeeth": 1000], components: [])
        XCTAssertEqual(range["reason"] as? String, "component.param.range.wheelTeeth")
    }

    func testCatalogAndExplain() throws {
        let e = MartyEngine(outputRoot: nil)
        let c = try e.catalog(compact: true, components: [])
        let components = try XCTUnwrap((c["components"] as? [String: Any])?["components"] as? [Any])
        XCTAssertEqual(components.count, MGSolidLibrary.builtIn.ids.count)
        let bytes = MartyJSON.data(c).count
        XCTAssertLessThan(bytes, 9000, "compact catalog grew to \(bytes) bytes (10 built-in components with anchor descriptions at the pin)")
        XCTAssertEqual((c["engine"] as? [String: Any])?["revision"] as? String, MartyPin.engineRevision)
        XCTAssertEqual(MartyJSON.data(c), MartyJSON.data(try MartyEngine(outputRoot: nil).catalog(compact: true, components: [])))

        let gear = try e.explain(id: "gear", components: [])
        XCTAssertEqual(gear["type"] as? String, "primitive")
        XCTAssertNotNil(gear["example"] as? [String: Any])
        let stage = try e.explain(id: "planetaryStage", components: [])
        XCTAssertEqual(stage["type"] as? String, "component")
        let unknown = try e.explain(id: "wormGear", components: [])
        XCTAssertEqual(unknown["reason"] as? String, "explain.unknown")
        XCTAssertTrue((unknown["known"] as? [String])?.contains("gear") == true)
    }

    func testRenderWritesAndReuses() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("marty-render-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let e = MartyEngine(outputRoot: root)
        let doc = try fixture("slider-crank-component.json")
        let r = try e.render(document: doc, ref: nil, components: [], size: "640x400", loop: false)
        XCTAssertEqual(r["ok"] as? Bool, true, "\(r)")
        let names = try XCTUnwrap(r["files"] as? [[String: Any]]).compactMap { $0["file"] as? String }
        XCTAssertEqual(names, ["hero.png", "exploded.png", "step-1.png", "step-2.png", "step-3.png", "step-4.png", "snapshot.json", "manifest.json"])
        let dir = URL(fileURLWithPath: try XCTUnwrap(r["directory"] as? String))
        XCTAssertEqual(dir.deletingLastPathComponent().standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path))
        let again = try e.render(document: nil, ref: r["ref"] as? String, components: [], size: "640x400", loop: false)
        XCTAssertEqual(again["reused"] as? Bool, true)
        XCTAssertEqual(MartyJSON.data(again["files"] ?? []), MartyJSON.data(r["files"] ?? []), "reuse returns the same files and digests")
        XCTAssertEqual(again["directory"] as? String, r["directory"] as? String)
        // Nothing but the result directory is left behind.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [dir.lastPathComponent])
    }

    func testRenderRefusesBadInput() throws {
        let e = MartyEngine(outputRoot: nil)
        XCTAssertThrowsError(try e.render(document: "{}", ref: nil, components: [], size: nil, loop: false)) {
            XCTAssertEqual(($0 as? ToolError)?.reason, "render.disabled")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("marty-render-tests-\(UUID().uuidString)")
        let on = MartyEngine(outputRoot: root)
        for bad in ["9999x10", "640x400x", "+640x400", "1280xabcx800", "640x", "x400", "６４０x400"] {
            XCTAssertThrowsError(try on.render(document: "{}", ref: nil, components: [], size: bad, loop: false), bad) {
                XCTAssertEqual(($0 as? ToolError)?.reason, "args.size")
            }
        }
        let refused = try on.render(document: #"{"v":1}"#, ref: nil, components: [], size: nil, loop: false)
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "a refused document must not create the output root")
    }
}
