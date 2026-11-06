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
                                   "user": ["file": stem + "-user.txt", "bytes": user.utf8.count]]
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
        if let c = r["checks"] as? [String: Any] { s["checks"] = c.filter { ["gearPairs", "gearsEngage", "meshesClosed", "minClearanceMM"].contains($0.key) } }
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
        let chosen = Array(wanted.filter { known.contains($0) }.prefix(Self.maxPlanIds))
        receipt["plan"] = ["reply": plan, "chosen": chosen, "dropped": wanted.filter { !chosen.contains($0) }]

        // 2. Author with the chosen parts explained (component entries without their full definitions).
        var parts: [String] = []
        for id in chosen {
            var e = try engine.explain(id: id, components: [])
            e.removeValue(forKey: "definition"); e.removeValue(forKey: "ok")
            parts.append(Self.compact(e))
        }
        let authorSystem = MartyPrompts.authorSystem(parts: parts.isEmpty ? "(none chosen; use the format guide)" : parts.joined(separator: "\n"),
                                                     example: MartyExamples.spurReduction)
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
            if let document {
                do { report = try engine.check(document: document, ref: nil, components: Array(components.prefix(MartyLimits.componentsPerRequest))) }
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
                let r = try engine.render(document: nil, ref: ref, components: acceptedComponents, size: options.size, loop: false)
                receipt["render"] = ["ok": r["ok"] ?? false, "directory": r["directory"] ?? NSNull(), "files": r["files"] ?? [Any](), "timing": r["timing"] ?? NSNull()]
                if let dir = r["directory"] as? String, let files = r["files"] as? [[String: Any]] {
                    for f in files { if let name = f["file"] as? String { stills[name] = dir + "/" + name } }
                }
            }
            // 4. Teach: the checked steps are the beats; the numbers come from the engine report.
            let says = report["steps"] as? [String] ?? []
            let lesson: [String: Any] = [
                "title": report["title"] ?? "", "ref": ref, "honesty": plan["honesty"] ?? "",
                "facts": ["ratios": report["ratios"] ?? [String: Any]()],
                "beats": says.enumerated().map { i, s -> [String: Any] in
                    ["n": i + 1, "say": s, "still": stills["step-\(i + 1).png"].map { $0 as Any } ?? NSNull()]
                },
            ]
            try MartyJSON.data(lesson).write(to: out.appendingPathComponent("lesson.json"))
            receipt["lesson"] = "lesson.json"

            // 5. Follow-up turn.
            if let followUp = options.followUp {
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
        for attempt in 0...options.repairs {
            let (text, i) = ask("followup", attempt: attempt, system: system, user: user)
            guard let text else { note(i, ["ok": false, "reason": "adapter"]); break }
            guard let reply = ReplyJSON.object(text), reply.keys.contains("patch") else {
                note(i, ["ok": false, "reason": "json"]); attempts.append(["ok": false, "reason": "json"])
                user += "\n\nYour reply was not one JSON object with a \"patch\" key. Reply again."
                continue
            }
            guard let patch = reply["patch"], !(patch is NSNull) else { noChange = true; note(i, ["ok": true, "patch": NSNull()]); break }
            var r: [String: Any]
            do { r = try engine.patch(document: nil, ref: ref, patch: patch, components: components, returnDocument: false) }
            catch let e as ToolError { r = ["ok": false, "reason": e.reason] }
            note(i, Self.outcome(r)); attempts.append(Self.outcome(r))
            if (r["ok"] as? Bool) == true { after = r; break }
            let reason = r["reason"] as? String ?? "unknown"
            user = MartyPrompts.followUpUser(question: question, document: docText, report: before, followUp: followUp)
                + "\n\nYour previous reply:\n\(text)\n\nThe engine refused the patch with reason `\(reason)`"
                + ((r["part"] as? String).map { " on part `\($0)`" } ?? "") + "." + (MartyPrompts.hint(for: reason).map { " \($0)" } ?? "")
                + " Reply with a corrected JSON object only."
        }
        result["attempts"] = attempts
        result["changed"] = after != nil
        if let after { result["after"] = Self.summary(after).merging(["ref": after["ref"] ?? NSNull()]) { a, _ in a } }
        guard after != nil || noChange else { result["ok"] = false; return result }
        let (answer, i) = ask("answer", attempt: 0, system: MartyPrompts.answerSystem(),
                              user: MartyPrompts.answerUser(followUp: followUp, before: before, after: after.map { Self.compact(Self.summary($0)) }))
        note(i, ["ok": answer != nil])
        result["ok"] = answer != nil
        result["answer"] = answer.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) as Any } ?? NSNull()
        return result
    }
}

/// Small accepted documents used as format examples in prompts. Tests check each one with the engine.
public enum MartyExamples {
    public static let spurReduction = #"{"v":1,"kind":"assembly","title":"Spur gear reduction","units":"mm","parts":[{"id":"pair","use":"spurPair","with":{"pinionTeeth":12,"wheelTeeth":36}}],"steps":[{"say":"A small pinion drives a larger wheel.","camera":"hero"},{"say":"Input: the pinion (12 teeth) turns once.","highlight":["pair.pinion"],"spin":1},{"say":"The wheel (36 teeth) turns 12/36 = 1/3 of a turn, the other way.","highlight":["pair.wheel"],"spin":1}]}"#
}
