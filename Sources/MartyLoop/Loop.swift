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
    /// Reasons of model calls that failed in the adapter (timeout, not logged in, ...): infrastructure, not the model.
    var adapterErrors: [String] = []

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
            adapterErrors.append((error as? AdapterError)?.reason ?? "adapter")
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

    /// The parts of a report a model needs to reason: title, part ids, solved ratios, the facts (as the learner would read
    /// them, with their tier) and the gear check.
    static func summary(_ r: [String: Any]) -> [String: Any] {
        var s: [String: Any] = [:]
        for k in ["ok", "reason", "part", "title", "partIds", "ratios"] { if let v = r[k] { s[k] = v } }
        if let f = factLines(r, limit: 80) { s["facts"] = f }
        // Only pass/fail checks: clearances are engine checks, not teaching facts, and they invite noise in answers.
        if let c = r["checks"] as? [String: Any] { s["checks"] = c.filter { ["gearPairs", "gearsEngage", "meshesClosed"].contains($0.key) } }
        return s
    }

    /// `name: text (tier)` for each engine fact, sorted, at most `limit`; nil when the report has none.
    static func factLines(_ r: [String: Any], limit: Int) -> [String]? {
        guard let facts = r["facts"] as? [String: Any], !facts.isEmpty else { return nil }
        let lines = facts.keys.sorted().map { k -> String in
            let f = facts[k] as? [String: Any] ?? [:]
            return "\(k): \(f["text"] as? String ?? "?") (\(f["tier"] as? String ?? "?"))"
        }
        return Array(lines.prefix(limit)) + (lines.count > limit ? ["(\(lines.count - limit) more)"] : [])
    }

    /// A refusal can come before the report exists (captions, claims and `expect` are checked while the document
    /// compiles). Marty then asks the engine about a copy without the parts that were refused: without steps and with a
    /// plain title for the facts (facts do not depend on captions); without `expect` (the document's parts and use-entry `set`
    /// entries) and also without steps and with a plain title for the read-back, because
    /// `expect` is checked before captions. Plain profile, so a strict warning cannot hide them. Nil when that copy is
    /// refused too.
    func strippedReport(_ document: Any, _ components: [Any], captions: Bool, expectations: Bool) -> [String: Any]? {
        var doc: [String: Any]
        if let d = document as? [String: Any] { doc = d }
        else if let s = document as? String, let d = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] { doc = d }
        else { return nil }
        // Captions are checked after `expect`, so the expect copy drops them too: a second error cannot hide the read-back.
        if captions || expectations { doc.removeValue(forKey: "steps"); doc["title"] = "Facts" }
        // expect is a v2 part key: legal on the document's parts and in a use entry's set (applied under the document's
        // keys). Component definitions are v1 and cannot hold it.
        if expectations, let parts = doc["parts"] as? [[String: Any]] { doc["parts"] = parts.map(Self.withoutExpect) }
        guard let r = try? engine.check(document: doc, ref: nil, components: components, strict: false), r["facts"] != nil else { return nil }
        return r
    }

    /// A part entry without `expect`, also inside its component `set` entries.
    static func withoutExpect(_ part: [String: Any]) -> [String: Any] {
        var p = part
        p.removeValue(forKey: "expect")
        if let set = p["set"] as? [String: Any] {
            p["set"] = set.mapValues { v -> Any in
                guard var inner = v as? [String: Any] else { return v }
                inner.removeValue(forKey: "expect")
                return inner
            }
        }
        return p
    }

    /// The facts block and read-back block for a repair prompt, from the report or from a stripped copy.
    func repairContext(reason: String, report: [String: Any], document: Any?, components: [Any]) -> (facts: String?, readBack: String?) {
        var facts: String? = nil, readBack: String? = nil
        if ["text.", "check.failed", "check.fact"].contains(where: { reason.hasPrefix($0) }) {
            let source = report["facts"] != nil ? report : document.flatMap { strippedReport($0, components, captions: true, expectations: false) }
            facts = source.flatMap { Self.factLines($0, limit: 80) }?.joined(separator: "\n")
        }
        if ["frame.", "joint.idle", "expect."].contains(where: { reason.hasPrefix($0) }) {
            let source = report["readBack"] != nil ? report : document.flatMap { strippedReport($0, components, captions: false, expectations: true) }
            readBack = (source?["readBack"] as? [String]).map { Array($0.prefix(48)).joined(separator: "\n") }
        }
        return (facts, readBack)
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
        var planAdapterFailed = false
        for attempt in 0..<2 {
            let (text, i) = ask("plan", attempt: attempt, system: planSystem, user: "Question: \(question)")
            if let t = text, let p = ReplyJSON.object(t) { plan = p; note(i, ["ok": true]); planAdapterFailed = false; break }
            note(i, ["ok": false, "reason": text == nil ? "adapter" : "plan.json"])
            planAdapterFailed = text == nil
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
        // When the model could not be reached for the plan, stop: more calls would only fail or wait again.
        if planAdapterFailed { attempts.append(["ok": false, "reason": "adapter"]) }
        for attempt in stride(from: 0, through: planAdapterFailed ? -1 : options.repairs, by: 1) {
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
                // Strict, as the engine recommends for model authors.
                do { report = try engine.check(document: document, ref: nil, components: components, strict: true) }
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
            // Engine context for the repair: the facts for caption and claim refusals, the read-back for frame,
            // idle-joint and expect refusals. Only what the engine actually returned is attached.
            let (facts, readBack) = repairContext(reason: reason, report: report, document: document, components: components)
            user = MartyPrompts.repairUser(question: question, plan: planText, previous: text, reason: reason, part: part,
                                           hint: MartyPrompts.hint(for: reason), facts: facts, readBack: readBack)
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
                    receipt["render"] = ["ok": r["ok"] ?? false, "reason": r["reason"] ?? NSNull(), "directory": r["directory"] ?? NSNull(),
                                         "files": r["files"] ?? [Any](), "timing": r["timing"] ?? NSNull()]
                    if let dir = r["directory"] as? String, let files = r["files"] as? [[String: Any]] {
                        for f in files { if let name = f["file"] as? String { stills[name] = dir + "/" + name } }
                    }
                } catch {
                    receipt["render"] = ["ok": false, "reason": (error as? ToolError)?.reason ?? "render.error", "error": "\(error)"]
                }
            }
            // 4. Teach: the beats are the engine-filled captions; in a v2 document every number in them comes from a fact
            // (rule N1), except steps marked unchecked. Each beat carries the tier the engine computed.
            let says = report["steps"] as? [String] ?? []
            let tiers = report["stepTiers"] as? [Any] ?? []
            let lesson: [String: Any] = [
                "title": report["title"] ?? "", "ref": ref, "honesty": plan["honesty"] ?? "",
                "version": report["version"] ?? 1,
                "sources": ["beats": "model words; in a v2 document every number in a caption is an engine fact (rule N1), except steps marked unchecked; see each beat's tier",
                            "facts": "engine: solved by MartyGraphics", "honesty": "model text from the plan"],
                "facts": ["ratios": report["ratios"] ?? [String: Any](), "facts": report["facts"] ?? [String: Any]()],
                "legend": (report["legend"] as? [String: Any])?["text"] ?? NSNull(),
                "beats": says.enumerated().map { i, s -> [String: Any] in
                    ["n": i + 1, "say": s, "tier": i < tiers.count ? tiers[i] : NSNull(),
                     "still": stills["step-\(i + 1).png"].map { $0 as Any } ?? NSNull()]
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
        if !adapterErrors.isEmpty { receipt["adapterErrors"] = adapterErrors }
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
            do { r = try engine.patch(document: nil, ref: ref, patch: merged, components: components, returnDocument: false, strict: true) }
            catch let e as ToolError { r = ["ok": false, "reason": e.reason] }
            note(i, Self.outcome(r)); attempts.append(Self.outcome(r))
            if (r["ok"] as? Bool) == true { after = r; acceptedPatch = merged; break }
            let reason = r["reason"] as? String ?? "unknown"
            // Facts of the changed model: the same patch with steps cleared and a plain title, plain profile.
            var facts: String? = nil
            if ["text.", "check.failed", "check.fact"].contains(where: { reason.hasPrefix($0) }), var p = merged as? [String: Any] {
                p["steps"] = [Any](); p["title"] = "Facts"
                if let fr = try? engine.patch(document: nil, ref: ref, patch: p, components: components, returnDocument: false, strict: false) {
                    facts = Self.factLines(fr, limit: 80)?.joined(separator: "\n")
                }
            }
            user = MartyPrompts.followUpUser(question: question, document: docText, report: before, followUp: followUp)
                + "\n\nYour previous reply:\n\(text)\n\nThe engine refused the patch with reason `\(reason)`"
                + ((r["part"] as? String).map { " on part `\($0)`" } ?? "") + "." + (MartyPrompts.hint(for: reason).map { " \($0)" } ?? "")
                + (facts.map { "\n\nFacts the engine solved for the changed model (name: value):\n\($0)" } ?? "")
                + "\n\nReply with a corrected JSON object only."
        }
        result["attempts"] = attempts
        result["changed"] = after != nil
        var ratiosChanged = false
        if let after {
            result["after"] = Self.summary(after).merging(["ref": after["ref"] ?? NSNull()]) { a, _ in a }
            ratiosChanged = MartyJSON.data(after["ratios"] ?? [String: Any]()) != MartyJSON.data(report["ratios"] ?? [String: Any]())
            result["ratiosChanged"] = ratiosChanged
        }
        // modelled: the engine solved the change (or none was needed). When it refused every change, the learner still
        // gets an honest answer that says the model cannot show it, with no new numbers.
        let modelled = after != nil || noChange
        result["modelled"] = modelled
        let lastReason = attempts.last?["reason"] as? String
        guard modelled || (lastReason != nil && lastReason != "adapter") else { result["ok"] = false; return result }
        // Did the engine see any patch? json and followup.textOnly never reach it.
        let marty: Set<String> = ["json", "followup.textOnly", "adapter"]
        let engineSawAPatch = attempts.contains { !marty.contains($0["reason"] as? String ?? "") }
        // Show the engine's own last reason when there is one (a later bad reply is Marty's json, not the engine's).
        let shownReason = engineSawAPatch ? (attempts.last { !marty.contains($0["reason"] as? String ?? "") }?["reason"] as? String ?? lastReason) : lastReason
        let (answer, i) = ask("answer", attempt: 0, system: modelled ? MartyPrompts.answerSystem() : MartyPrompts.answerRefusedSystem(),
                              user: MartyPrompts.answerUser(followUp: followUp, before: before, after: after.map { Self.compact(Self.summary($0)) },
                                                            patch: acceptedPatch.map { Self.compact($0) }, ratiosChanged: ratiosChanged,
                                                            refused: modelled ? nil : shownReason, engineSawAPatch: engineSawAPatch))
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
    public static let formatExample = #"{"v":2,"kind":"assembly","title":"A shaft held in two bearings","units":"mm","parts":[{"id":"base","use":"housingBase","at":[0,0,-1]},{"id":"shaft","use":"shaftWithBearing","with":{"radius":6,"length":80}}],"annotations":{"labels":[{"id":"lShaft","at":{"part":"shaft.input","offset":[0,0,60]},"text":"Shaft"},{"id":"lRated","at":{"world":[0,-70,20]},"text":"Rated 3000 rpm","unchecked":"maker's figure"}],"arrows":[{"id":"aW","meaning":"force","cause":"gravity","from":"base.base","to":{"part":"base.base","offset":[0,0,-40]},"text":"Weight"}]},"steps":[{"say":"Two bearings hold a shaft in line on a base.","camera":"hero"},{"say":"Input: the shaft makes {shaft.input.speed} turn for each input turn.","highlight":["shaft.input"],"spin":1,"check":[{"value":"shaft.input.speed","eq":1}]},{"say":"Cut open: the lower bearing rings the shaft.","section":{"normal":[0,-1,0],"parts":["shaft.lowerBearing"]},"highlight":["shaft.lowerBearing"]},{"say":"Seen through the base.","ghost":["base.base"]}]}"#
}
