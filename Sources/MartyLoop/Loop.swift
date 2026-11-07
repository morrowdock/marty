// SPDX-License-Identifier: Apache-2.0
import Foundation
import MartyEngine

/// The reference Marty agent: plan -> choose parts -> author -> check -> repair (from exact reasons) -> render -> teach,
/// and an optional follow-up turn (patch -> check -> answer). Every model call and every engine result is recorded in
/// a run receipt. Model text is only ever parsed as JSON data and given to the engine; it is never run.
@MainActor
public final class MartyLoop {
    public struct Options {
        public var repairs = 3
        public var render = false
        public var size = "1280x800"
        public var followUp: String? = nil
        public init() {}
    }

    public static let receiptFormat = "marty.run-receipt/v1"
    public static let maxPlanIds = 6

    let engine: MartyEngine
    let model: ModelAdapter
    let options: Options
    let out: URL
    var calls: [[String: Any]] = []
    var savedSystems: Set<String> = []

    /// `out` must not exist; its parent must. Renders go to `out/render`.
    public init(model: ModelAdapter, out: URL, options: Options) throws {
        // Check options before any model call is paid for.
        guard (0...3).contains(options.repairs) else { throw AdapterError(reason: "loop.repairs", detail: "repairs is 0-3") }
        guard MartyEngine.parseSize(options.size) != nil else {
            throw AdapterError(reason: "loop.size", detail: "size is WIDTHxHEIGHT, width 320-1920 and height 200-1200")
        }
        guard (options.followUp?.utf8.count ?? 0) <= 2000 else { throw AdapterError(reason: "loop.followUp", detail: "at most 2000 bytes") }
        let fm = FileManager.default
        do { try fm.createDirectory(at: out, withIntermediateDirectories: false) }
        catch { throw AdapterError(reason: "loop.out", detail: "cannot create a NEW directory at \(out.path)") }
        try fm.createDirectory(at: out.appendingPathComponent("calls"), withIntermediateDirectories: false)
        self.out = out
        self.model = model
        self.options = options
        self.engine = MartyEngine(outputRoot: options.render ? out.appendingPathComponent("render", isDirectory: true) : nil)
    }

    // MARK: recording

    func write(_ text: String, _ name: String) { try? Data(text.utf8).write(to: out.appendingPathComponent(name)) }

    /// One model call, recorded: prompt sizes and digests, the reply file, time and adapter facts.
    func ask(_ phase: String, attempt: Int, system: String, user: String) -> (text: String?, index: Int) {
        let n = calls.count + 1
        let sysSHA = MartyJSON.sha256(Data(system.utf8))
        if !savedSystems.contains(sysSHA) { savedSystems.insert(sysSHA); write(system, "calls/system-\(sysSHA.prefix(12)).txt") }
        let stem = String(format: "calls/%02d-%@-%d", n, phase, attempt)
        write(user, stem + "-user.txt")
        var call: [String: Any] = ["n": n, "phase": phase, "attempt": attempt,
                                   "system": ["file": "calls/system-\(sysSHA.prefix(12)).txt", "bytes": system.utf8.count, "sha256": sysSHA],
                                   "user": ["file": stem + "-user.txt", "bytes": user.utf8.count, "sha256": MartyJSON.sha256(Data(user.utf8))]]
        do {
            let r = try model.reply(system: system, user: user)
            write(r.text, stem + "-reply.txt")
            call["reply"] = ["file": stem + "-reply.txt", "bytes": r.text.utf8.count]
            call["seconds"] = (r.seconds * 10).rounded() / 10
            call["model"] = r.meta
            calls.append(call)
            return (r.text, calls.count - 1)
        } catch {
            call["error"] = "\(error)"
            calls.append(call)
            return (nil, calls.count - 1)
        }
    }

    func note(_ index: Int, _ outcome: [String: Any]) { calls[index]["outcome"] = outcome }

    static func outcome(_ r: [String: Any]) -> [String: Any] {
        ["ok": r["ok"] ?? false, "reason": r["reason"] ?? NSNull(), "part": r["part"] ?? NSNull(), "ref": r["ref"] ?? NSNull(),
         "error": r["error"] ?? NSNull(), "component": r["component"] ?? NSNull()]
    }

    static func compact(_ o: Any) -> String { MartyJSON.string(o) }

    /// The parts of a report a model needs to reason: title, part ids, solved ratios and the gear check.
    static func summary(_ r: [String: Any]) -> [String: Any] {
        var s: [String: Any] = [:]
        for k in ["ok", "reason", "part", "title", "partIds", "ratios"] { if let v = r[k] { s[k] = v } }
        // Only pass/fail checks: clearances are engine checks, not teaching facts, and they invite noise in answers.
        if let c = r["checks"] as? [String: Any] { s["checks"] = c.filter { ["gearPairs", "gearsEngage", "meshesClosed"].contains($0.key) } }
        return s
    }

    // MARK: the loop

    public func run(question: String) throws -> [String: Any] {
        let started = Date()
        var receipt: [String: Any] = [
            "format": Self.receiptFormat, "prompts": MartyPrompts.version, "model": model.id,
            "engine": ["repository": MartyPin.engineRepository, "revision": MartyPin.engineRevision],
            "question": question, "options": ["repairs": options.repairs, "render": options.render, "size": options.size],
            "startedAt": ISO8601DateFormatter().string(from: started),
        ]

        // 1. Plan: the compact catalog only.
        let catalog = try engine.catalog(compact: true, components: [])
        let known = Set(((catalog["components"] as? [String: Any])?["components"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
            .union(MartyPrimitive.all.map(\.id))
        let planSystem = MartyPrompts.planSystem(catalog: Self.compact(catalog))
        var plan: [String: Any] = [:]
        for attempt in 0..<2 {
            let (text, i) = ask("plan", attempt: attempt, system: planSystem, user: "Question: \(question)")
            if let t = text, let p = ReplyJSON.object(t) { plan = p; note(i, ["ok": true]); break }
            note(i, ["ok": false, "reason": text == nil ? "adapter" : "plan.json"])
        }
        let wanted = ((plan["components"] as? [String] ?? []) + (plan["primitives"] as? [String] ?? []))
        var seen = Set<String>()
        let chosen = Array(wanted.filter { known.contains($0) && seen.insert($0).inserted }.prefix(Self.maxPlanIds))
        receipt["plan"] = ["reply": plan, "chosen": chosen, "dropped": wanted.filter { !chosen.contains($0) }]

        // 2. Author with the chosen parts explained (component entries without their full definitions).
        var parts: [String] = []
        for id in chosen {
            var e = try engine.explain(id: id, components: [])
            e.removeValue(forKey: "definition"); e.removeValue(forKey: "ok")
            parts.append(Self.compact(e))
        }
        let authorSystem = MartyPrompts.authorSystem(parts: parts.isEmpty ? "(none chosen; use the format guide)" : parts.joined(separator: "\n"),
                                                     example: MartyExamples.formatExample)
        let planText = Self.compact(plan)
        var user = MartyPrompts.authorUser(question: question, plan: planText)
        var accepted: [String: Any]? = nil
        var acceptedComponents: [Any] = []
        var attempts: [[String: Any]] = []
        for attempt in 0...options.repairs {
            let (text, i) = ask(attempt == 0 ? "author" : "repair", attempt: attempt, system: authorSystem, user: user)
            guard let text else { note(i, ["ok": false, "reason": "adapter"]); attempts.append(["ok": false, "reason": "adapter"]); break }
            let reply = ReplyJSON.object(text)
            var document: Any? = nil
            if let reply { document = reply["document"] ?? (reply["kind"] != nil ? reply as Any : nil) }
            let components = reply?["components"] as? [Any] ?? []
            var report: [String: Any]
            if components.count > MartyLimits.componentsPerRequest {
                report = ["ok": false, "reason": "components.count", "part": NSNull()]
            } else if let document {
                do { report = try engine.check(document: document, ref: nil, components: components) }
                catch let e as ToolError { report = ["ok": false, "reason": e.reason] }
            } else {
                report = ["ok": false, "reason": "json", "part": NSNull()]
            }
            note(i, Self.outcome(report))
            attempts.append(Self.outcome(report))
            if (report["ok"] as? Bool) == true { accepted = report; acceptedComponents = components; break }
            let reason = report["reason"] as? String ?? "unknown"
            var part = report["part"] as? String
            if let c = report["component"] as? Int { part = "components[\(c)]" + (part.map { " / \($0)" } ?? "") }
            user = MartyPrompts.repairUser(question: question, plan: planText, previous: text, reason: reason, part: part,
                                           hint: MartyPrompts.hint(for: reason))
        }
        receipt["attempts"] = attempts
        receipt["accepted"] = accepted != nil

        if let report = accepted, let ref = report["ref"] as? String {
            receipt["final"] = Self.summary(report).merging(["ref": ref, "triangles": report["triangles"] ?? 0, "steps": report["steps"] ?? [Any]()]) { a, _ in a }
            // 3. Render.
            var stills: [String: String] = [:]
            if options.render {
                // A render failure (for example no Metal device) is recorded; the checked lesson still stands.
                do {
                    let r = try engine.render(document: nil, ref: ref, components: acceptedComponents, size: options.size, loop: false)
                    receipt["render"] = ["ok": r["ok"] ?? false, "directory": r["directory"] ?? NSNull(), "files": r["files"] ?? [Any](), "timing": r["timing"] ?? NSNull()]
                    if let dir = r["directory"] as? String, let files = r["files"] as? [[String: Any]] {
                        for f in files { if let name = f["file"] as? String { stills[name] = dir + "/" + name } }
                    }
                } catch {
                    receipt["render"] = ["ok": false, "error": "\(error)"]
                }
            }
            // 4. Teach: the beats are the model's step texts (the engine checks their length and characters, not their
            // numbers); the facts are the engine's solved values. Each is labelled with where it comes from.
            let says = report["steps"] as? [String] ?? []
            let lesson: [String: Any] = [
                "title": report["title"] ?? "", "ref": ref, "honesty": plan["honesty"] ?? "",
                "sources": ["beats": "model text; the engine checked length and characters, not the numbers in it",
                            "facts": "engine: solved by MartyGraphics", "honesty": "model text from the plan"],
                "facts": ["ratios": report["ratios"] ?? [String: Any]()],
                "beats": says.enumerated().map { i, s -> [String: Any] in
                    ["n": i + 1, "say": s, "still": stills["step-\(i + 1).png"].map { $0 as Any } ?? NSNull()]
                },
            ]
            try MartyJSON.data(lesson).write(to: out.appendingPathComponent("lesson.json"))
            receipt["lesson"] = "lesson.json"

            // 5. Follow-up turn.
            // An empty follow-up (the out-of-scope bench questions have none) means no follow-up turn.
            if let followUp = options.followUp?.trimmingCharacters(in: .whitespacesAndNewlines), !followUp.isEmpty {
                receipt["followUp"] = try self.followUp(question: question, followUp: followUp, ref: ref, report: report, components: acceptedComponents)
            }
        }

        let finished = Date()
        receipt["seconds"] = (finished.timeIntervalSince(started) * 10).rounded() / 10
        receipt["calls"] = calls
        receipt["modelSeconds"] = ((calls.compactMap { $0["seconds"] as? Double }.reduce(0, +)) * 10).rounded() / 10
        receipt["contextBytes"] = ["plan": planSystem.utf8.count, "author": authorSystem.utf8.count]
        let data = try JSONSerialization.data(withJSONObject: MartyJSON.sanitized(receipt), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: out.appendingPathComponent("receipt.json"))
        return receipt
    }

    func followUp(question: String, followUp: String, ref: String, report: [String: Any], components: [Any]) throws -> [String: Any] {
        guard let docText = engine.canonicalDocument(ref: ref) else { return ["ok": false, "reason": "ref.unknown"] }
        let before = Self.compact(Self.summary(report))
        let system = MartyPrompts.followUpSystem()
        var user = MartyPrompts.followUpUser(question: question, document: docText, report: before, followUp: followUp)
        var result: [String: Any] = ["question": followUp]
        var after: [String: Any]? = nil
        var attempts: [[String: Any]] = []
        var noChange = false
        var acceptedPatch: Any? = nil
        for attempt in 0...options.repairs {
            let (text, i) = ask("followup", attempt: attempt, system: system, user: user)
            guard let text else { note(i, ["ok": false, "reason": "adapter"]); attempts.append(["ok": false, "reason": "adapter"]); break }
            guard let reply = ReplyJSON.object(text), reply.keys.contains("patch") else {
                note(i, ["ok": false, "reason": "json"]); attempts.append(["ok": false, "reason": "json"])
                user += "\n\nYour reply was not one JSON object with a \"patch\" key. Reply again."
                continue
            }
            guard let patch = reply["patch"], !(patch is NSNull) else { noChange = true; note(i, ["ok": true, "patch": NSNull()]); break }
            // A what-if must change the model, not only its words: a patch of only title and steps would narrate a
            // change the engine never solved. Refuse it like an engine refusal, so the model can repair or reply null.
            if let keys = (patch as? [String: Any]).map({ Set($0.keys) }), !keys.isEmpty, keys.isSubset(of: ["title", "steps"]) {
                let o: [String: Any] = ["ok": false, "reason": "followup.textOnly"]
                note(i, o); attempts.append(o)
                user = MartyPrompts.followUpUser(question: question, document: docText, report: before, followUp: followUp)
                    + "\n\nYour previous reply:\n\(text)\n\nThat patch changes only text (title or steps), so the engine solves the same "
                    + "motion as before and the new text would not be true. Change parts, drives or constraints so the engine solves the "
                    + "new case (for a component, \"<instance>.<inner id>\" edits an inner part), or reply {\"patch\": null}."
                continue
            }
            var r: [String: Any]
            let merged = Self.mergingWith(patch, base: docText)
            do { r = try engine.patch(document: nil, ref: ref, patch: merged, components: components, returnDocument: false) }
            catch let e as ToolError { r = ["ok": false, "reason": e.reason] }
            note(i, Self.outcome(r)); attempts.append(Self.outcome(r))
            if (r["ok"] as? Bool) == true { after = r; acceptedPatch = merged; break }
            let reason = r["reason"] as? String ?? "unknown"
            user = MartyPrompts.followUpUser(question: question, document: docText, report: before, followUp: followUp)
                + "\n\nYour previous reply:\n\(text)\n\nThe engine refused the patch with reason `\(reason)`"
                + ((r["part"] as? String).map { " on part `\($0)`" } ?? "") + "." + (MartyPrompts.hint(for: reason).map { " \($0)" } ?? "")
                + " Reply with a corrected JSON object only."
        }
        result["attempts"] = attempts
        result["changed"] = after != nil
        var ratiosChanged = false
        if let after {
            result["after"] = Self.summary(after).merging(["ref": after["ref"] ?? NSNull()]) { a, _ in a }
            ratiosChanged = MartyJSON.data(after["ratios"] ?? [String: Any]()) != MartyJSON.data(report["ratios"] ?? [String: Any]())
            result["ratiosChanged"] = ratiosChanged
        }
        guard after != nil || noChange else { result["ok"] = false; return result }
        let (answer, i) = ask("answer", attempt: 0, system: MartyPrompts.answerSystem(),
                              user: MartyPrompts.answerUser(followUp: followUp, before: before, after: after.map { Self.compact(Self.summary($0)) },
                                                            patch: acceptedPatch.map { Self.compact($0) }, ratiosChanged: ratiosChanged))
        note(i, ["ok": answer != nil])
        result["ok"] = answer != nil
        result["answer"] = answer.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) as Any } ?? NSNull()
        result["answerSource"] = "model text written from the engine reports; its numbers are not checked"
        return result
    }
}

extension MartyLoop {
    /// The engine replaces a part field as a whole, so `{"stage": {"with": {"planets": 4}}}` would reset every other
    /// parameter of `stage` to its default. A model means "change planets"; merge its `with` into the base document's
    /// `with` (a null value removes a parameter) so only what was asked changes.
    static func mergingWith(_ patch: Any, base docText: String) -> Any {
        guard var p = patch as? [String: Any], let edits = p["parts"] as? [String: Any],
              let doc = try? JSONSerialization.jsonObject(with: Data(docText.utf8)) as? [String: Any],
              let parts = doc["parts"] as? [[String: Any]] else { return patch }
        var out = edits
        for (id, edit) in edits {
            guard var e = edit as? [String: Any], let newWith = e["with"] as? [String: Any],
                  let basePart = parts.first(where: { $0["id"] as? String == id && $0["use"] != nil }) else { continue }
            // A patch that swaps the component starts from that component's own defaults.
            if let use = e["use"] as? String, use != basePart["use"] as? String { continue }
            var w = basePart["with"] as? [String: Any] ?? [:]
            for (k, v) in newWith { if v is NSNull { w.removeValue(forKey: k) } else { w[k] = v } }
            e["with"] = w
            out[id] = e
        }
        p["parts"] = out
        return p
    }
}

/// Small accepted documents used as format examples in prompts. Tests check each one with the engine.
/// The example is about no bench subject (no gears, cranks or blades), so it shows the format without giving away an answer.
public enum MartyExamples {
    public static let formatExample = #"{"v":1,"kind":"assembly","title":"A shaft held in two bearings","units":"mm","parts":[{"id":"base","use":"housingBase","at":[0,0,-1]},{"id":"shaft","use":"shaftWithBearing","with":{"radius":6,"length":80}},{"id":"label","name":"Name plate","material":"plastic.teal","shape":{"box":{"size":[40,4,14],"chamfer":0.5}},"at":[0,-70,7]}],"steps":[{"say":"Two bearings hold a shaft in line so that it can turn freely.","camera":"hero"},{"say":"Input: the shaft turns. The bearings and the base stay still.","highlight":["shaft.input"],"spin":1},{"say":"Exploded: the base, the bearings and the shaft.","explode":1,"camera":"iso"}]}"#
}
