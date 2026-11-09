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
        /// The research phase (web search through the adapter's research call). An adapter without web tools skips it.
        public var research = true
        public var researchTurns = 12
        /// Fetch each cited page and check its quote (`FactTable.checkQuotes`); a row whose quotes are not found is UNKNOWN.
        public var quoteCheck = true
        public init() {}
    }

    public static let receiptFormat = "marty.run-receipt/v1"
    /// The page fetcher of the quote check (tests replace it with a stub).
    public static var fetcher: PageFetcher = PinnedFetcher()
    public static let maxPlanIds = 6

    let engine: MartyEngine
    let model: ModelAdapter
    let options: Options
    let out: URL
    var calls: [[String: Any]] = []
    var savedSystems: Set<String> = []
    /// Reasons of model calls that failed in the adapter (timeout, not logged in, ...): infrastructure, not the model.
    var adapterErrors: [String] = []
    /// The research phase's fact table (empty without research), and its prompt block.
    var facts = FactTable.empty
    var factBlock: String { facts.promptBlock }

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
    func ask(_ phase: String, attempt: Int, system: String, user: String, research: ResearchLimits? = nil) -> (text: String?, index: Int) {
        let n = calls.count + 1
        let sysSHA = MartyJSON.sha256(Data(system.utf8))
        if !savedSystems.contains(sysSHA) { savedSystems.insert(sysSHA); write(system, "calls/system-\(sysSHA.prefix(12)).txt") }
        let stem = String(format: "calls/%02d-%@-%d", n, phase, attempt)
        write(user, stem + "-user.txt")
        var call: [String: Any] = ["n": n, "phase": phase, "attempt": attempt,
                                   "system": ["file": "calls/system-\(sysSHA.prefix(12)).txt", "bytes": system.utf8.count, "sha256": sysSHA],
                                   "user": ["file": stem + "-user.txt", "bytes": user.utf8.count, "sha256": MartyJSON.sha256(Data(user.utf8))]]
        do {
            let r = try research.map { try model.research(system: system, user: user, limits: $0) } ?? model.reply(system: system, user: user)
            write(r.text, stem + "-reply.txt")
            call["reply"] = ["file": stem + "-reply.txt", "bytes": r.text.utf8.count]
            call["seconds"] = (r.seconds * 10).rounded() / 10
            call["model"] = r.meta
            calls.append(call)
            return (r.text, calls.count - 1)
        } catch {
            call["error"] = "\(error)"
            // A research call that fails is recorded in the receipt's research block; the run goes on without a table.
            if research == nil { adapterErrors.append((error as? AdapterError)?.reason ?? "adapter") }
            calls.append(call)
            return (nil, calls.count - 1)
        }
    }

    func note(_ index: Int, _ outcome: [String: Any]) { calls[index]["outcome"] = outcome }

    /// The full detail of a refusal for the repair prompt: every structured field the engine gave (location, limit,
    /// actual, path, cause, by, closer, fix, and the newer repair and suggest), and the texts of the refused document
    /// that are over their length limit (measured as the engine counts them, with the facts the report has).
    /// Engine advice that would ghost a part some label or arrow is anchored on (`anchored`) is left out: following it
    /// would hide that annotation.
    static func refusalDetail(_ r: [String: Any], document: Any?, anchored: Set<String>? = nil) -> String? {
        let anchored = anchored ?? document.map(Self.anchoredParts) ?? []
        var lines: [String] = []
        if let rep = r["repair"] as? String, !rep.isEmpty, !MartyPrompts.ghostsAnchored(rep, anchored) { lines.append("Engine repair: \(rep)") }
        var fields: [String: Any] = [:]
        for k in ["location", "limit", "actual", "path", "cause", "by", "closer", "fix", "suggest", "detail"] {
            guard let v = r[k], !(v is NSNull) else { continue }
            if let t = v as? String, MartyPrompts.ghostsAnchored(t, anchored) { continue }
            if let o = v as? [String: Any] {
                let kept = o.filter { !($0.value is NSNull) }
                if !kept.isEmpty { fields[k] = kept }
            } else { fields[k] = v }
        }
        if !fields.isEmpty { lines.append("Engine detail: " + MartyJSON.string(fields)) }
        let long = document.map { TextBudget.issues($0) } ?? []
        if !long.isEmpty { lines.append("Texts over their length limit:\n" + long.prefix(8).map { "- \($0.line)" }.joined(separator: "\n")) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The document with the engine's checked suggestions applied: a label's "at" or a pointer's "to" set to its
    /// anchor `suggest`, and a hidden arrow's "from" (and "to") set to its arrow `suggest` (`{"from", "to"?}`). The
    /// engine checks all printed suggestions together (one joint fixed point), so they are applied at once. An
    /// annotation given two different values for one field (from different views) is left alone (a conflict).
    /// Returns the ids it changed.
    static func applySuggestions(_ document: Any, _ issues: [[String: Any]]) -> (document: Any, applied: [String]) {
        guard var d = document as? [String: Any] else { return (document, []) }
        var byId: [String: [String: (value: Any, data: Data)]] = [:]
        var conflicts = Set<String>()
        for i in issues {
            guard let id = i["id"] as? String, let sug = i["suggest"], !(sug is NSNull) else { continue }
            let changes: [String: Any]
            if i["check"] as? String == "arrow" {
                guard let o = sug as? [String: Any] else { continue }
                changes = o.filter { ["from", "to"].contains($0.key) }
            } else {
                changes = [i["kind"] as? String == "pointer" || i["kind"] as? String == "arrow" ? "to" : "at": sug]
            }
            for (key, value) in changes {
                let data = MartyJSON.data(value)
                if let old = byId[id]?[key], old.data != data { conflicts.insert(id) }
                byId[id, default: [:]][key] = (value, data)
            }
        }
        var applied: [String] = []
        func fix(_ ann: inout [String: Any]) {
            for kind in ["labels", "arrows"] {
                guard var list = ann[kind] as? [[String: Any]] else { continue }
                for n in list.indices {
                    guard let id = list[n]["id"] as? String, let s = byId[id], !conflicts.contains(id) else { continue }
                    var changed = false
                    for (key, v) in s where MartyJSON.data(list[n][key] ?? NSNull()) != v.data { list[n][key] = v.value; changed = true }
                    if changed { applied.append(id) }
                }
                ann[kind] = list
            }
        }
        if var ann = d["annotations"] as? [String: Any] { fix(&ann); d["annotations"] = ann }
        if var solid = d["solid"] as? [String: Any], var ann = solid["annotations"] as? [String: Any] {
            fix(&ann); solid["annotations"] = ann; d["solid"] = solid
        }
        return (d, applied)
    }

    /// The parts that labels and pointers are anchored on (their "at" or "to"), so a fix that ghosts one is dropped.
    static func anchoredParts(_ document: Any) -> Set<String> {
        guard let d = document as? [String: Any] else { return [] }
        var out = Set<String>()
        for ann in [d["annotations"], (d["solid"] as? [String: Any])?["annotations"]].compactMap({ $0 as? [String: Any] }) {
            for kind in ["labels", "arrows"] {
                for a in ann[kind] as? [[String: Any]] ?? [] {
                    for k in ["at", "to", "from"] {
                        if let p = a[k] as? String { out.insert(p) } else if let p = (a[k] as? [String: Any])?["part"] as? String { out.insert(p) }
                    }
                }
            }
        }
        return out
    }

    /// The document with every non-integer number in a board table's cells written as text, so the engine shows it
    /// with every published digit (85.06, not its rounded 85.1).
    static func exactTableNumbers(_ document: Any) -> Any {
        func walk(_ v: Any) -> Any {
            if var o = v as? [String: Any] {
                for (k, x) in o { o[k] = walk(x) }
                func exact(_ rows: [[Any]]) -> [[Any]] {
                    rows.map { row in
                        row.map { cell -> Any in
                            guard let n = cell as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return cell }
                            let d = n.doubleValue
                            return d.rounded() == d ? cell : MartyLoop.trimmedDecimal("\(d)")
                        }
                    }
                }
                // Every cell matrix: a table's "cells", a board override's "cells", a beat op setting "cells".
                if let rows = o["cells"] as? [[Any]] { o["cells"] = exact(rows) }
                if o["key"] as? String == "cells", let rows = o["value"] as? [[Any]] { o["value"] = exact(rows) }
                return o
            }
            if let a = v as? [Any] { return a.map(walk) }
            return v
        }
        return walk(document)
    }

    /// The anchor and arrow issues of a refusal: the anchor issue it names (`anchor`) first, then the others
    /// (`anchorIssues`), then the hidden arrow it names (`arrow`) and the others (`arrowIssues`), each marked
    /// `"check": "arrow"`.
    static func anchorIssues(_ r: [String: Any]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        func add(_ i: [String: Any]) { if !out.contains(where: { MartyJSON.data($0) == MartyJSON.data(i) }) { out.append(i) } }
        if let a = r["anchor"] as? [String: Any] { add(a) }
        for i in r["anchorIssues"] as? [[String: Any]] ?? [] { add(i) }
        var arrows: [[String: Any]] = []
        if let a = r["arrow"] as? [String: Any] { arrows.append(a) }
        arrows += r["arrowIssues"] as? [[String: Any]] ?? []
        for var a in arrows { a["check"] = "arrow"; add(a) }
        return out
    }

    static func outcome(_ r: [String: Any]) -> [String: Any] {
        var o: [String: Any] = ["ok": r["ok"] ?? false, "reason": r["reason"] ?? NSNull(), "part": r["part"] ?? NSNull(),
                                "ref": r["ref"] ?? NSNull(), "error": r["error"] ?? NSNull(), "component": r["component"] ?? NSNull()]
        if let v = r["visibility"] { o["visibility"] = v }
        if let l = r["limit"] { o["limit"] = l }
        if let u = r["unsourced"] { o["unsourced"] = u }
        if let d = r["direction"] { o["direction"] = d }
        if let a = r["anchor"] { o["anchor"] = a }
        if let a = r["arrow"] { o["arrow"] = a }
        return o
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
        // An explainer's facts and read-back are those of its 3D view: check that view as an assembly.
        if doc["kind"] as? String == "explainer" {
            guard var solid = doc["solid"] as? [String: Any] else { return nil }
            solid["kind"] = "assembly"; solid["units"] = solid["units"] ?? "mm"
            doc = solid
        }
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
            "question": question, "options": ["repairs": options.repairs, "render": options.render, "size": options.size,
                                              "research": options.research, "researchTurns": options.researchTurns,
                                              "quoteCheck": options.quoteCheck],
            "startedAt": ISO8601DateFormatter().string(from: started),
        ]

        // 0. Research: one bounded web search call returns the fact table that the plan, author and follow-up may state.
        if options.research, !model.supportsResearch {
            receipt["research"] = ["ok": false, "reason": "research.unavailable"]
        } else if options.research {
            let limits = ResearchLimits(maxTurns: options.researchTurns)
            let (text, i) = ask("research", attempt: 0, system: MartyPrompts.researchSystem(maxSearches: max(1, limits.maxTurns - 1)),
                                user: "Question: \(question)", research: limits)
            var block: [String: Any] = ["maxTurns": limits.maxTurns, "blockedDomains": limits.blockedDomains]
            // `webTools` counts each WebSearch and WebFetch use from the call's event stream (the adapter stops the
            // call past the limit); `turns` is the CLI's own turn count.
            if let m = calls[i]["model"] as? [String: Any] { block["turns"] = m["num_turns"] ?? NSNull(); block["webTools"] = m["webTools"] ?? NSNull() }
            if let text, var table = FactTable.parse(text, blocked: limits.blockedDomains) {
                if options.quoteCheck { table.checkQuotes(fetcher: Self.fetcher) }
                // Stopped early (a tool or turn limit, an error, an unreadable final table): the rows confirmed so far,
                // marked partial and warned about with the cause.
                if let m = calls[i]["model"] as? [String: Any], m["partial"] as? Bool == true {
                    table.partial = true
                    let cause = m["partialCause"] as? String ?? "web tool limit"
                    block["partialCause"] = cause
                    block["warning"] = "research stopped early (\(cause)); the table holds only the rows confirmed before that"
                }
                facts = table
                block.merge(table.json) { a, _ in a }
                block["ok"] = true
                note(i, ["ok": true, "rows": table.rows.count, "partial": table.partial])
            } else {
                let reason = text == nil ? ((calls[i]["error"] as? String).map { $0.components(separatedBy: ":").first ?? "adapter" } ?? "adapter") : "research.json"
                block["ok"] = false; block["reason"] = reason
                // Research was tried and stopped (a limit, a timeout, an error, an unreadable reply) before it
                // confirmed a fact: no table, a warning with the cause, and the prompts say facts may still be published.
                let cause = reason == "adapter.research.turns" ? "its tool limit" : reason == "adapter.timeout" ? "a timeout"
                    : reason == "research.json" ? "an unreadable reply" : "an error (\(reason))"
                block["warning"] = "research stopped at \(cause) before it confirmed a fact; there is no fact table"
                facts = FactTable(needed: true, rows: [], downgrades: [], partial: true)
                note(i, ["ok": false, "reason": reason])
            }
            receipt["research"] = block
        }

        // 1. Plan: the compact catalog only (and the fact table).
        let catalog = try engine.catalog(compact: true, components: [])
        let known = Set(((catalog["components"] as? [String: Any])?["components"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
            .union(MartyPrimitive.all.map(\.id))
        let planSystem = MartyPrompts.planSystem(catalog: Self.compact(catalog))
        var plan: [String: Any] = [:]
        var planAdapterFailed = false
        for attempt in 0..<2 {
            let (text, i) = ask("plan", attempt: attempt, system: planSystem, user: "Question: \(question)\n\n\(factBlock)")
            if let t = text, let p = ReplyJSON.object(t) { plan = p; note(i, ["ok": true]); planAdapterFailed = false; break }
            note(i, ["ok": false, "reason": text == nil ? "adapter" : "plan.json"])
            planAdapterFailed = text == nil
        }
        // A question about how something flies needs its thrust against weight in "given": ask once more if it is missing.
        var planLint: [String: Any]? = nil
        // Only when the fact table has a thrust row: without one, a re-ask would only invite a guess.
        let tableHasThrust = facts.rows.contains { r in
            r.label != .unknown && r.claim.lowercased().contains("thrust") && r.value.rangeOfCharacter(from: .decimalDigits) != nil
        }
        if !planAdapterFailed, !plan.isEmpty, tableHasThrust, Self.asksHowItFlies(question), !Self.givenHasThrust(plan) {
            let u = "Question: \(question)\n\n\(factBlock)\n\nYour plan:\n\(Self.compact(plan))\n\n" + MartyPrompts.planThrustRepair
            // Only the reply's "given" is taken, and only when it now names thrust: the rest of the plan stays, and a
            // partial, empty or bad reply (or an adapter failure) keeps the original plan.
            let (text, i) = ask("plan", attempt: 2, system: planSystem, user: u)
            let given = text.flatMap(ReplyJSON.object)?["given"]
            let fixed = given.map { Self.givenHasThrust(["given": $0]) } ?? false
            if fixed, let given { plan["given"] = given }
            note(i, ["ok": fixed, "reason": text == nil ? "adapter" : "plan.given.thrust"])
            planLint = ["reason": "plan.given.thrust", "fixed": fixed]
        }
        let wanted = ((plan["components"] as? [String] ?? []) + (plan["primitives"] as? [String] ?? []))
        var seen = Set<String>()
        let chosen = Array(wanted.filter { known.contains($0) && seen.insert($0).inserted }.prefix(Self.maxPlanIds))
        receipt["plan"] = ["reply": plan, "chosen": chosen, "dropped": wanted.filter { !chosen.contains($0) }]
            .merging(planLint.map { ["lint": $0] } ?? [:]) { a, _ in a }

        // 2. Author with the chosen parts explained (component entries without their full definitions).
        var parts: [String] = []
        for id in chosen {
            var e = try engine.explain(id: id, components: [])
            e.removeValue(forKey: "definition"); e.removeValue(forKey: "ok")
            parts.append(Self.compact(e))
        }
        let explainerForm = (plan["form"] as? String) == "explainer"
        let authorSystem = MartyPrompts.authorSystem(parts: parts.isEmpty ? "(none chosen; use the format guide)" : parts.joined(separator: "\n"),
                                                     example: MartyExamples.formatExample,
                                                     explainer: explainerForm ? MartyExamples.explainerExample : nil)
        let planText = Self.compact(plan)
        var user = MartyPrompts.authorUser(question: question, plan: planText, table: factBlock)
        var accepted: [String: Any]? = nil
        var acceptedComponents: [Any] = []
        var attempts: [[String: Any]] = []
        // The best engine-accepted document that fails Marty's own lint (fewest findings; a later one wins a tie), with
        // its components and attempt. One lint repair at most.
        var fallback: (report: [String: Any], components: [Any], lint: [String], attempt: Int)? = nil
        var lintRepairUsed = false
        // When the model could not be reached for the plan, stop: more calls would only fail or wait again.
        if planAdapterFailed { attempts.append(["ok": false, "reason": "adapter"]) }
        for attempt in stride(from: 0, through: planAdapterFailed ? -1 : options.repairs, by: 1) {
            let (text, i) = ask(attempt == 0 ? "author" : "repair", attempt: attempt, system: authorSystem, user: user)
            guard let text else { note(i, ["ok": false, "reason": "adapter"]); attempts.append(["ok": false, "reason": "adapter"]); break }
            let reply = ReplyJSON.object(text)
            var document: Any? = nil
            var trimmedNow: [String] = []
            var autoFixed: [String] = []
            if let reply { document = reply["document"] ?? (reply["kind"] != nil ? reply as Any : nil) }
            let components = reply?["components"] as? [Any] ?? []
            var report: [String: Any]
            if components.count > MartyLimits.componentsPerRequest {
                report = ["ok": false, "reason": "components.count", "part": NSNull()]
            } else if let doc0 = document {
                // Over-long texts are cut at a word before the check (recorded); then strict, as the engine recommends.
                let (doc1, cut) = TextBudget.trimmed(Self.exactTableNumbers(doc0))
                document = doc1; trimmedNow = cut
                do { report = try engine.check(document: doc1, ref: nil, components: components, strict: true) }
                catch let e as ToolError { report = ["ok": false, "reason": e.reason] }
                // The engine's checked anchor suggestions are applied by Marty and checked again (at most 3 rounds)
                // before the model is asked: each was verified on a copy, so only the issues left go to the model.
                var round = 0
                while (report["ok"] as? Bool) != true, round < 3, let cur = document {
                    let (fixed, applied) = Self.applySuggestions(cur, Self.anchorIssues(report))
                    guard !applied.isEmpty else { break }
                    round += 1
                    guard let r2 = try? engine.check(document: fixed, ref: nil, components: components, strict: true) else { break }
                    document = fixed; report = r2; autoFixed += applied
                }
            } else {
                report = ["ok": false, "reason": "json", "part": NSNull()]
            }
            // After Marty applied suggestions, every repair (engine, fact, lint) gets that document, so the model does
            // not undo them.
            let previous = autoFixed.isEmpty ? text
                : "(Marty applied the engine's checked anchor and arrow suggestions for " + autoFixed.map { "`\($0)`" }.joined(separator: ", ")
                    + "; this is the document after them.)\n" + MartyJSON.string(["document": document ?? NSNull(), "components": components])
            var outcome = Self.outcome(report)
            if !trimmedNow.isEmpty { outcome["trimmed"] = trimmedNow }
            if !autoFixed.isEmpty { outcome["autoFixed"] = autoFixed }
            note(i, outcome)
            attempts.append(outcome)
            if (report["ok"] as? Bool) == true, let document,
               case let unsourced = FactCheck.findings(document, evidence: .build(table: facts, question: question, report: report, model: document)),
               let reason = FactCheck.reason(unsourced) {
                // A number, year or version that is not in the fact table, the question or the model: refused like an
                // engine refusal (a normal repair; no fallback).
                attempts[attempts.count - 1]["ok"] = false
                attempts[attempts.count - 1]["reason"] = reason
                attempts[attempts.count - 1]["engineOk"] = true
                attempts[attempts.count - 1]["unsourced"] = unsourced.map(\.line)
                note(i, attempts[attempts.count - 1])
                user = MartyPrompts.repairUser(question: question, plan: planText, previous: previous, reason: reason, part: nil,
                                               hint: MartyPrompts.factRepair + "\n" + unsourced.map { "- \($0.line)" }.joined(separator: "\n"),
                                               table: factBlock)
                continue
            }
            if (report["ok"] as? Bool) == true {
                // Marty's lint on the accepted document (too many texts in a step, a comparison with no figure). It
                // only asks for one more repair when one is left; the accepted document is kept as the fallback.
                let lint = document.map(Self.documentLint) ?? []
                if lint.isEmpty { accepted = report; acceptedComponents = components; break }
                if fallback == nil || lint.count <= fallback!.lint.count { fallback = (report, components, lint, attempts.count - 1) }
                attempts[attempts.count - 1]["reason"] = "marty.lint"
                attempts[attempts.count - 1]["lint"] = lint
                attempts[attempts.count - 1]["engineOk"] = true
                attempts[attempts.count - 1]["ok"] = false
                // No repair left, or the one lint repair was used: the best accepted document stands (after the loop).
                if lintRepairUsed || attempt == options.repairs { break }
                lintRepairUsed = true
                user = MartyPrompts.repairUser(question: question, plan: planText, previous: previous, reason: "marty.lint", part: nil,
                                               hint: MartyPrompts.lintRepair + "\n" + lint.map { "- \($0)" }.joined(separator: "\n"),
                                               table: factBlock)
                continue
            }
            let reason = report["reason"] as? String ?? "unknown"
            var part = report["part"] as? String
            if let c = report["component"] as? Int { part = "components[\(c)]" + (part.map { " / \($0)" } ?? "") }
            // Engine context for the repair: the facts for caption and claim refusals, the read-back for frame,
            // idle-joint and expect refusals. Only what the engine actually returned is attached.
            let (facts, readBack) = repairContext(reason: reason, report: report, document: document, components: components)
            user = MartyPrompts.repairUser(question: question, plan: planText, previous: previous, reason: reason, part: part,
                                           hint: MartyPrompts.hint(for: reason), facts: facts, readBack: readBack,
                                           visibility: report["visibility"] as? [String: Any], limit: report["limit"] as? [String: Any],
                                           table: factBlock, anchors: Self.anchorIssues(report),
                                           detail: Self.refusalDetail(report, document: document),
                                           anchoredParts: document.map(Self.anchoredParts) ?? [])
        }
        if accepted == nil, let f = fallback {
            accepted = f.report; acceptedComponents = f.components
            receipt["lint"] = f.lint; receipt["lintAttempt"] = f.attempt
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
                "kind": report["kind"] ?? "assembly", "version": report["version"] ?? 1,
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
        // An explainer has no engine patch format: the model sends the whole changed explainer, which the engine checks.
        if (report["kind"] as? String) == "explainer" {
            return try explainerFollowUp(question: question, followUp: followUp, docText: docText, before: before, report: report,
                                         components: components)
        }
        let system = MartyPrompts.followUpSystem()
        var user = MartyPrompts.followUpUser(question: question, document: docText, report: before, followUp: followUp, table: factBlock)
        var result: [String: Any] = ["question": followUp]
        var after: [String: Any]? = nil
        var attempts: [[String: Any]] = []
        var noChange = false
        var acceptedPatch: Any? = nil
        // Annotations Marty moved by the engine's checked suggestions in the accepted follow-up (beyond the patch).
        var acceptedAutoFixed: [String] = []
        var acceptedStep: [String: Any]? = nil
        var acceptedPush: PoseText.Push? = nil
        var stepPush: PoseText.Push? = nil
        var engineChecked = false
        for attempt in 0...options.repairs {
            stepPush = nil
            let (text, i) = ask("followup", attempt: attempt, system: system, user: user)
            guard let text else { note(i, ["ok": false, "reason": "adapter"]); attempts.append(["ok": false, "reason": "adapter"]); break }
            guard var reply = ReplyJSON.object(text), reply.keys.contains("patch") || reply["step"] is [String: Any] else {
                note(i, ["ok": false, "reason": "json"]); attempts.append(["ok": false, "reason": "json"])
                user += "\n\nYour reply was not one JSON object with a \"patch\" or a \"step\" key. Reply again."
                continue
            }
            // A pose what-if: one new step (or a replaced one, "replace": <step number>) that poses, shows or hides parts
            // for that step only, sent to the engine as a steps patch; the base model stays as it is.
            var stepReply: [String: Any]? = nil
            if let step = reply["step"] as? [String: Any] {
                guard let steps = Self.stepsWith(step, replace: reply["replace"], base: docText) else {
                    note(i, ["ok": false, "reason": "json"]); attempts.append(["ok": false, "reason": "json"])
                    user += "\n\n\"replace\" must be the number of an existing step (1 to the number of steps), or left out to add a step. Reply again."
                    continue
                }
                stepReply = step
                reply["patch"] = ["steps": steps]
            }
            guard let patch = reply["patch"], !(patch is NSNull) else { noChange = true; note(i, ["ok": true, "patch": NSNull()]); break }
            // A what-if must change the model, not only its words: a patch of only title and steps would narrate a
            // change the engine never solved (unless a step now poses, shows or hides parts). Refuse it like an engine
            // refusal, so the model can repair or reply null.
            // A steps patch goes to the engine; whether it changed what the steps show is decided from the engine's
            // effective step views below.
            let viewsOnly = (patch as? [String: Any]).map { !$0.isEmpty && Set($0.keys).isSubset(of: ["title", "steps"]) } ?? false
            if viewsOnly, (patch as? [String: Any])?["steps"] == nil {
                let o: [String: Any] = ["ok": false, "reason": "followup.textOnly"]
                note(i, o); attempts.append(o)
                user = MartyPrompts.followUpUser(question: question, document: docText, report: before, followUp: followUp, table: factBlock)
                    + "\n\nYour previous reply:\n\(text)\n\nThat patch changes only text (title or steps), so the engine solves the same "
                    + "motion as before and the new text would not be true. Change parts, drives or constraints so the engine solves the "
                    + "new case (for a component, \"<instance>.<inner id>\" edits an inner part), or reply {\"patch\": null}."
                continue
            }
            var r: [String: Any]
            let (trimmedPatch, patchCut) = TextBudget.trimmed(Self.mergingWith(patch, base: docText))
            let merged = trimmedPatch
            engineChecked = true
            do { r = try engine.patch(document: nil, ref: ref, patch: merged, components: components, returnDocument: false, strict: true) }
            catch let e as ToolError { r = ["ok": false, "reason": e.reason] }
            // A patch cannot move annotations, so the engine's checked anchor and arrow suggestions are applied by Marty
            // to the patched whole document, which is checked again (at most 3 rounds); the accepted model is then that
            // document (its `ref`), and the attempt lists the fixed ids.
            var patchAutoFixed: [String] = []
            var fixedWhole: [String: Any]? = nil
            if (r["ok"] as? Bool) != true, !Self.anchorIssues(r).isEmpty,
               var whole = (try? engine.patch(document: nil, ref: ref, patch: merged, components: components, returnDocument: true, strict: false))?["document"] {
                var rr = r, round = 0
                while (rr["ok"] as? Bool) != true, round < 3 {
                    let (fixed, applied) = Self.applySuggestions(whole, Self.anchorIssues(rr))
                    guard !applied.isEmpty else { break }
                    round += 1
                    guard let r2 = try? engine.check(document: fixed, ref: nil, components: components, strict: true) else { break }
                    whole = fixed; rr = r2; patchAutoFixed += applied
                }
                if !patchAutoFixed.isEmpty { r = rr; fixedWhole = whole as? [String: Any] }
            }
            // A title or steps patch that leaves every step's effective pose and visibility as before changes only words.
            if (r["ok"] as? Bool) == true, viewsOnly, Self.effectiveViews(r) == Self.effectiveViews(report) {
                let o: [String: Any] = ["ok": false, "reason": "followup.textOnly"]
                note(i, o); attempts.append(o)
                user = MartyPrompts.followUpUser(question: question, document: docText, report: before, followUp: followUp, table: factBlock)
                    + "\n\nYour previous reply:\n\(text)\n\nThat change leaves the model and every step's pose and visibility as before "
                    + "(it changes only text), so the new text would not be true. Change parts, drives or constraints, or add a step "
                    + "whose \"pose\" really moves a part, or reply {\"patch\": null}."
                continue
            }
            // The patch's own text (title, steps, part names) is checked for unsourced facts like a document.
            if (r["ok"] as? Bool) == true {
                let base = (try? JSONSerialization.jsonObject(with: Data(docText.utf8))) as? [String: Any]
                let unsourced = FactCheck.findings(merged, evidence: .build(table: facts, question: question, report: r, model: base,
                                                                            extra: [followUp] + Self.numberLeaves((merged as? [String: Any])?["parts"])
                                                                                + Self.numberLeaves((merged as? [String: Any])?["params"])),
                                                   filledBy: base)
                if let reason = FactCheck.reason(unsourced) { r = ["ok": false, "reason": reason, "unsourced": unsourced.map(\.line)] }
            }
            // The words of each changed posed step (from a "step" reply or a raw steps patch) must agree with what its
            // shown thrust arrows do at the pose; the engine poses the patched document itself.
            // (After an auto-fix, the document checked is the fixed whole document, not the patch replayed.)
            if (r["ok"] as? Bool) == true,
               let patched = fixedWhole ?? (try? engine.patch(document: nil, ref: ref, patch: merged, components: components, returnDocument: true, strict: true))?["document"] as? [String: Any] {
                let base = (try? JSONSerialization.jsonObject(with: Data(docText.utf8))) as? [String: Any]
                let says = (patched["steps"] as? [[String: Any]] ?? []).map { $0["say"] as? String ?? "" }
                let baseSays = (base?["steps"] as? [[String: Any]] ?? []).map { $0["say"] as? String ?? "" }
                let (push, wrong) = PoseText.check(engine: engine, document: patched, base: base, says: says, baseSays: baseSays,
                                                   components: components)
                stepPush = push
                if !wrong.isEmpty { r = ["ok": false, "reason": "followup.direction", "direction": wrong] }
            }
            var o = Self.outcome(r)
            if !patchCut.isEmpty { o["trimmed"] = patchCut }
            if !patchAutoFixed.isEmpty { o["autoFixed"] = patchAutoFixed }
            note(i, o); attempts.append(o)
            if (r["ok"] as? Bool) == true {
                after = r; acceptedPatch = merged; acceptedPush = stepPush; acceptedAutoFixed = patchAutoFixed
                // The accepted step as checked (after trimming): from the patched steps at its place.
                if stepReply != nil, let steps = (merged as? [String: Any])?["steps"] as? [Any] {
                    let n = (reply["replace"] as? NSNumber).map { $0.intValue - 1 } ?? steps.count - 1
                    acceptedStep = (n >= 0 && n < steps.count ? steps[n] : steps.last) as? [String: Any]
                }
                break
            }
            let reason = r["reason"] as? String ?? "unknown"
            // A patch keeps the base document's annotations: their anchored parts guard the repair's ghost advice.
            let baseAnchored = ((try? JSONSerialization.jsonObject(with: Data(docText.utf8))) as Any?).map(Self.anchoredParts) ?? []
            // Facts of the changed model: the same patch with steps cleared and a plain title, plain profile.
            var facts: String? = nil
            if ["text.", "check.failed", "check.fact"].contains(where: { reason.hasPrefix($0) }), var p = merged as? [String: Any] {
                p["steps"] = [Any](); p["title"] = "Facts"
                if let fr = try? engine.patch(document: nil, ref: ref, patch: p, components: components, returnDocument: false, strict: false) {
                    facts = Self.factLines(fr, limit: 80)?.joined(separator: "\n")
                }
            }
            user = MartyPrompts.followUpUser(question: question, document: docText, report: before, followUp: followUp, table: factBlock)
                + "\n\nYour previous reply:\n\(text)"
                + (fixedWhole.map { "\n\n(Marty applied the engine's checked anchor and arrow suggestions for "
                    + patchAutoFixed.map { "`\($0)`" }.joined(separator: ", ") + " to the patched model; this is the whole document after your patch and them. "
                    + "A patch cannot move annotations: keep your patch, or change it so the model stays valid.)\n" + MartyJSON.string(["document": $0]) } ?? "")
                + "\n\nThe engine refused the patch with reason `\(reason)`"
                + ((r["part"] as? String).map { " on part `\($0)`" } ?? "") + "." + (MartyPrompts.hint(for: reason).map { " \($0)" } ?? "")
                + ((r["visibility"] as? [String: Any]).flatMap(MartyPrompts.visibilityLine).map { " \($0)" } ?? "")
                + ((r["limit"] as? [String: Any]).flatMap(MartyPrompts.limitLine).map { " \($0)" } ?? "")
                + ((r["unsourced"] as? [String]).map { " " + MartyPrompts.factRepair + "\n" + $0.map { "- \($0)" }.joined(separator: "\n") } ?? "")
                + (MartyPrompts.anchorLines(Self.anchorIssues(r), anchoredParts: baseAnchored).map { "\n" + $0 } ?? "")
                + (Self.refusalDetail(r, document: merged, anchored: baseAnchored).map { "\n" + $0 } ?? "")
                + ((r["direction"] as? [String]).map { " " + MartyPrompts.directionRepair + " " + ($0.first ?? "") + "\n" + $0.dropFirst().map { "- \($0)" }.joined(separator: "\n") } ?? "")
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
        // The engine saw a change when it was called at least once (a words-only steps patch is decided after it).
        let engineSawAPatch = engineChecked || attempts.contains { !marty.contains($0["reason"] as? String ?? "") }
        // Show the engine's own last reason when there is one (a later bad reply is Marty's json, not the engine's).
        let shownReason = engineSawAPatch ? (attempts.last { !marty.contains($0["reason"] as? String ?? "") }?["reason"] as? String ?? lastReason) : lastReason
        // Force arrows (not gravity) that the accepted patch may have moved: their shown direction is schematic.
        var moved: [String] = []
        if let p = acceptedPatch as? [String: Any],
           let doc = (try? JSONSerialization.jsonObject(with: Data(docText.utf8))) as? [String: Any] {
            moved = Self.movedForceArrows(annotations: doc["annotations"], parts: doc["parts"] as? [[String: Any]] ?? [],
                                          moved: Set((p["parts"] as? [String: Any] ?? [:]).keys).union(Self.viewMovedIds(before: report, after: after ?? [:])),
                                          all: !Set(p.keys).isDisjoint(with: ["params", "constraints", "joints"]))
            // Arrows Marty moved by the engine's checked suggestions are moved too.
            let arrowIds = Set(((doc["annotations"] as? [String: Any])?["arrows"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
            moved += acceptedAutoFixed.filter { arrowIds.contains($0) && !moved.contains($0) }
            result["forceArrowsMoved"] = moved
        }
        if !acceptedAutoFixed.isEmpty { result["autoFixed"] = acceptedAutoFixed }
        if let acceptedStep { result["step"] = acceptedStep }
        if let acceptedPush { result["push"] = acceptedPush.summary }
        // Given figures go to a modelled answer only; the refused answer keeps to the report before.
        let given = modelled ? Self.givenFigures(try? JSONSerialization.jsonObject(with: Data(docText.utf8))) : []
        let evidence = given + (modelled ? facts.lines : []) + Self.factTexts(report) + Self.factTexts(after) + Self.numberLeaves(report["ratios"])
            + Self.numberLeaves(after?["ratios"]) + Self.numberLeaves(acceptedPatch)
        let answer = writeAnswer(system: modelled ? MartyPrompts.answerSystem() : MartyPrompts.answerRefusedSystem(),
                                 user: MartyPrompts.answerUser(followUp: followUp, before: before, after: after.map { Self.compact(Self.summary($0)) },
                                                               patch: acceptedPatch.map { Self.compact($0) + (acceptedAutoFixed.isEmpty ? ""
                                                                   : " (and Marty moved the annotations " + acceptedAutoFixed.map { "`\($0)`" }.joined(separator: ", ")
                                                                   + " so they stay visible; their direction and length are unchanged)") },
                                                               ratiosChanged: ratiosChanged,
                                                               refused: modelled ? nil : shownReason, engineSawAPatch: engineSawAPatch,
                                                               movedForceArrows: moved, given: given, table: modelled ? factBlock : nil,
                                                               push: acceptedPush?.summary),
                                 sources: evidence + (modelled ? [question, followUp] : []), push: acceptedPush, result: &result)
        result["ok"] = answer != nil
        result["answer"] = answer.map { $0 as Any } ?? NSNull()
        result["answerSource"] = "model text written from the engine reports; its numbers are not checked"
        return result
    }
}

extension MartyLoop {
    /// A follow-up on an explainer: the whole changed explainer, checked by the engine (strict), at most `repairs` repairs;
    /// a change of words only (the same board and solid) is refused as followup.textOnly. Then an answer from the reports.
    func explainerFollowUp(question: String, followUp: String, docText: String, before: String, report: [String: Any],
                           components: [Any]) throws -> [String: Any] {
        let base = (try? JSONSerialization.jsonObject(with: Data(docText.utf8))) as? [String: Any] ?? [:]
        let views = Self.modelContent
        let system = MartyPrompts.followUpExplainerSystem()
        var user = MartyPrompts.followUpUser(question: question, document: docText, report: before, followUp: followUp, table: factBlock)
        var result: [String: Any] = ["question": followUp]
        var attempts: [[String: Any]] = []
        var after: [String: Any]? = nil
        var acceptedChange: String? = nil
        var acceptedDoc: [String: Any]? = nil
        var acceptedPush: PoseText.Push? = nil
        var stepPush: PoseText.Push? = nil
        var engineChecked = false
        var moved: [String] = []
        var noChange = false
        for attempt in 0...options.repairs {
            stepPush = nil
            let (text, i) = ask("followup", attempt: attempt, system: system, user: user)
            guard let text else { note(i, ["ok": false, "reason": "adapter"]); attempts.append(["ok": false, "reason": "adapter"]); break }
            guard let reply = ReplyJSON.object(text), reply.keys.contains("document") else {
                note(i, ["ok": false, "reason": "json"]); attempts.append(["ok": false, "reason": "json"])
                user += "\n\nYour reply was not one JSON object with a \"document\" key. Reply again."
                continue
            }
            // Only an explicit null means "no change"; any other non-object is a reply to repair.
            if reply["document"] is NSNull { noChange = true; note(i, ["ok": true, "document": NSNull()]); break }
            guard let changed0 = reply["document"] as? [String: Any] else {
                note(i, ["ok": false, "reason": "json"]); attempts.append(["ok": false, "reason": "json"])
                user += "\n\n\"document\" must be the whole changed explainer object, or null. Reply again."
                continue
            }
            let (trimmedDoc, explainerCut) = TextBudget.trimmed(Self.exactTableNumbers(changed0))
            var changed = trimmedDoc as? [String: Any] ?? changed0
            var r: [String: Any]
            var autoFixed: [String] = []
            if changed["kind"] as? String != "explainer" {
                r = ["ok": false, "reason": "followup.kind"]
            } else {
                engineChecked = true
                do { r = try engine.check(document: changed, ref: nil, components: components, strict: true) }
                catch let e as ToolError { r = ["ok": false, "reason": e.reason] }
                // As for the author: the engine's checked anchor suggestions are applied and checked again first.
                var round = 0
                while (r["ok"] as? Bool) != true, round < 3 {
                    let (fixed, applied) = Self.applySuggestions(changed, Self.anchorIssues(r))
                    guard !applied.isEmpty, let fixedDoc = fixed as? [String: Any] else { break }
                    round += 1
                    guard let r2 = try? engine.check(document: fixedDoc, ref: nil, components: components, strict: true) else { break }
                    changed = fixedDoc; r = r2; autoFixed += applied
                }
                // The same model content and the same effective beat views (poses and visibility): words only.
                if (r["ok"] as? Bool) == true, views(changed) == views(base), Self.effectiveViews(r) == Self.effectiveViews(report) {
                    r = ["ok": false, "reason": "followup.textOnly"]
                }
                if (r["ok"] as? Bool) == true {
                    let unsourced = FactCheck.findings(changed, evidence: .build(table: facts, question: question, report: r, model: changed,
                                                                                 extra: [followUp]))
                    if let reason = FactCheck.reason(unsourced) { r = ["ok": false, "reason": reason, "unsourced": unsourced.map(\.line)] }
                }
                // A new or edited beat with a pose: its words must agree with its shown thrust arrows at the pose (the
                // explainer's solid with one step per beat, posed by the engine).
                if (r["ok"] as? Bool) == true, let doc = PoseText.assembly(explainer: changed) {
                    let says = (changed["beats"] as? [[String: Any]] ?? []).map { $0["say"] as? String ?? "" }
                    let baseSays = (base["beats"] as? [[String: Any]] ?? []).map { $0["say"] as? String ?? "" }
                    let (push, wrong) = PoseText.check(engine: engine, document: doc, base: PoseText.assembly(explainer: base),
                                                       says: says, baseSays: baseSays, components: components)
                    stepPush = push
                    if !wrong.isEmpty { r = ["ok": false, "reason": "followup.direction", "direction": wrong] }
                }
            }
            var o = Self.outcome(r)
            if !explainerCut.isEmpty { o["trimmed"] = explainerCut }
            if !autoFixed.isEmpty { o["autoFixed"] = autoFixed }
            note(i, o); attempts.append(o)
            if (r["ok"] as? Bool) == true {
                after = r; acceptedDoc = changed; acceptedChange = Self.changeSummary(from: base, to: changed); acceptedPush = stepPush
                moved = Self.movedForceArrows(explainerFrom: base, to: changed, viewMoved: Self.viewMovedIds(before: report, after: r))
                break
            }
            let reason = r["reason"] as? String ?? "unknown"
            let (facts, readBack) = repairContext(reason: reason, report: r, document: changed, components: components)
            // Built in parts: one long concatenation is too slow to type-check.
            var u = MartyPrompts.followUpUser(question: question, document: docText, report: before, followUp: followUp, table: factBlock)
            u += "\n\nYour previous reply:\n\(text)"
            if !autoFixed.isEmpty {
                u += "\n\n(Marty applied the engine's checked anchor suggestions for " + autoFixed.map { "`\($0)`" }.joined(separator: ", ")
                    + "; this is the document after them.)\n" + MartyJSON.string(["document": changed])
            }
            u += "\n\nThe engine refused it with reason `\(reason)`"
            if let part = r["part"] as? String { u += " on part `\(part)`" }
            u += "."
            if reason == "followup.textOnly" { u += " Only the words changed: change the model (its solid, its board items, a beat's ops, or a beat view whose pose really moves a part)." }
            if reason == "followup.kind" { u += " The changed document must stay an explainer (kind explainer)." }
            if let h = MartyPrompts.hint(for: reason) { u += " \(h)" }
            if let v = (r["visibility"] as? [String: Any]).flatMap(MartyPrompts.visibilityLine) { u += " \(v)" }
            if let l = (r["limit"] as? [String: Any]).flatMap(MartyPrompts.limitLine) { u += " \(l)" }
            if let lines = r["unsourced"] as? [String] { u += " " + MartyPrompts.factRepair + "\n" + lines.map { "- \($0)" }.joined(separator: "\n") }
            if let a = MartyPrompts.anchorLines(Self.anchorIssues(r), anchoredParts: Self.anchoredParts(changed)) { u += "\n" + a }
            if let d = Self.refusalDetail(r, document: changed, anchored: Self.anchoredParts(changed)) { u += "\n" + d }
            if let d = r["direction"] as? [String] { u += " " + MartyPrompts.directionRepair + " " + (d.first ?? "") + "\n" + d.dropFirst().map { "- \($0)" }.joined(separator: "\n") }
            if let facts { u += "\n\nFacts the engine solved (name: value):\n\(facts)" }
            if let readBack { u += "\n\nEngine read-back:\n\(readBack)" }
            u += "\n\nReply with a corrected JSON object only."
            user = u
        }
        result["attempts"] = attempts
        result["changed"] = after != nil
        let modelled = after != nil || noChange
        result["modelled"] = modelled
        var ratiosChanged = false
        if let after {
            result["after"] = Self.summary(after).merging(["ref": after["ref"] ?? NSNull()]) { a, _ in a }
            ratiosChanged = MartyJSON.data(after["ratios"] ?? [String: Any]()) != MartyJSON.data(report["ratios"] ?? [String: Any]())
            result["ratiosChanged"] = ratiosChanged
            result["forceArrowsMoved"] = moved
            if let acceptedPush { result["push"] = acceptedPush.summary }
        }
        let lastReason = attempts.last?["reason"] as? String
        guard modelled || (lastReason != nil && lastReason != "adapter") else { result["ok"] = false; return result }
        let marty: Set<String> = ["json", "followup.textOnly", "followup.kind", "adapter"]
        let engineSawAChange = engineChecked || attempts.contains { !marty.contains($0["reason"] as? String ?? "") }
        let shownReason = engineSawAChange ? (attempts.last { !marty.contains($0["reason"] as? String ?? "") }?["reason"] as? String ?? lastReason) : lastReason
        let given = modelled ? Self.givenFigures(acceptedDoc ?? base) : []
        let changeObject = acceptedChange.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
        let evidence = given + (modelled ? facts.lines : []) + Self.factTexts(report) + Self.factTexts(after) + Self.numberLeaves(report["ratios"])
            + Self.numberLeaves(after?["ratios"]) + Self.numberLeaves(changeObject)
        let answer = writeAnswer(system: modelled ? MartyPrompts.answerSystem() : MartyPrompts.answerRefusedSystem(),
                                 user: MartyPrompts.answerUser(followUp: followUp, before: before, after: after.map { Self.compact(Self.summary($0)) },
                                                               patch: acceptedChange, ratiosChanged: ratiosChanged,
                                                               refused: modelled ? nil : shownReason, engineSawAPatch: engineSawAChange,
                                                               movedForceArrows: moved, given: given, table: modelled ? factBlock : nil,
                                                               push: acceptedPush?.summary),
                                 sources: evidence + (modelled ? [question, followUp] : []), push: acceptedPush, result: &result)
        result["ok"] = answer != nil
        result["answer"] = answer.map { $0 as Any } ?? NSNull()
        result["answerSource"] = "model text written from the engine reports; its numbers are not checked"
        return result
    }

    /// The follow-up answer. A sentence that compares sizes or shares ("most", "the majority", "all of the") with no
    /// hedge and no number from the sources (the document with its given figures, the engine reports, the change) gets
    /// one rewrite request; `answerLint` records it and whether the rewrite cleared it.
    func writeAnswer(system: String, user: String, sources: [String], push: PoseText.Push? = nil, result: inout [String: Any]) -> String? {
        let (first, i) = ask("answer", attempt: 0, system: system, user: user)
        note(i, ["ok": first != nil])
        guard var answer = first?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        func problems(_ text: String) -> (comparative: [String], unsourced: [String]) {
            let c = Self.unsupportedComparatives(text, sources: sources)
            // Direction words that disagree with the posed step count with the unsourced sentences.
            let d = push.map { PoseText.disagreements(text, push: $0) } ?? []
            return (c, (Self.unsourcedSentences(text, sources: sources) + d).filter { !c.contains($0) })
        }
        let (comparative, unsourced) = problems(answer)
        let flagged = comparative + unsourced
        guard !flagged.isEmpty else { return answer }
        var lint: [String: Any] = ["reason": unsourced.isEmpty ? "answer.comparative" : "answer.unsourced", "sentences": flagged, "fixed": false]
        let (second, j) = ask("answer", attempt: 1, system: system, user: user + "\n\nYour previous answer:\n\(answer)\n\n"
            + MartyPrompts.answerComparativeRepair + "\n" + flagged.joined(separator: "\n"))
        note(j, ["ok": second != nil, "reason": lint["reason"] ?? "answer.comparative"])
        if let s = second?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            answer = s
            let again = problems(s)
            lint["fixed"] = again.comparative.isEmpty && again.unsourced.isEmpty
        }
        result["answerLint"] = lint
        return answer
    }

    /// Sentences of an answer with a number or a version that is in none of the sources (the fact table, the
    /// reports, the change, the question).
    static func unsourcedSentences(_ text: String, sources: [String]) -> [String] {
        var nums = Set(sources.flatMap(numbers))
        // A solved decimal may be written as its exact fraction or its inverse.
        for t in nums where t.contains(".") {
            guard let v = Double(t), v != 0 else { continue }
            for (p, q) in [FactCheck.fraction(abs(v)), FactCheck.fraction(1 / abs(v))].compactMap({ $0 }) { nums.insert(String(p)); nums.insert(String(q)) }
        }
        let e = FactCheck.Evidence(numbers: nums, versions: Set(sources.flatMap(FactCheck.versions)))
        return sentences(text).filter { !FactCheck.check("answer", $0, e, placeholders: false).isEmpty }
    }

    static let flightWords = #"(?i)\b(fly|flies|flying|flight|flown|hover|hovers|hovering|airborne|take ?off|takes off|soar|soars)\b"#
    static let liftWords = #"(?i)\b(lift|lifts|lifting|lift-off|liftoff)\b"#
    static let flightContext = #"(?i)\b(jet|jets|jetpack|suit|aircraft|airplane|aeroplane|plane|drone|helicopter|quadcopter|rocket|wing|wings|rotor|propeller|balloon|airship|glider|bird|thrust|vtol|hovercraft)\b"#
    /// A question about how something flies: a flight word, or a lift word with a flight context ("a hydraulic lift"
    /// is not one).
    static func asksHowItFlies(_ question: String) -> Bool {
        func has(_ re: String) -> Bool { question.range(of: re, options: .regularExpression) != nil }
        return has(flightWords) || (has(liftWords) && has(flightContext))
    }

    /// A "given" entry that names thrust and has a number.
    static func givenHasThrust(_ plan: [String: Any]) -> Bool {
        let given = (plan["given"] as? [Any] ?? []).map { "\($0)" }
        return given.contains { $0.lowercased().contains("thrust") && $0.rangeOfCharacter(from: .decimalDigits) != nil }
    }

    // "all the" and "all its" are left out: "the upward parts of all the thrusts balance the weight" is no share claim.
    static let comparativeWords = #"(?i)\b(most|mostly|majority|all of|the bulk|nearly all|almost all|mainly|largely|more than|less than|twice|half of|the largest|the biggest|the lion's share)\b"#
    static let hedgeWords = #"(?i)\b(about|roughly|around|approximately|estimated?|reported|schematic|not checked|may|might|perhaps|likely)\b"#

    /// The numbers in a text ("1,500" and "1.5" stay whole; a trailing period is not a decimal point), normalized:
    /// no thousands commas, no trailing decimal zeros ("1.50" and "1.5", "3000.0" and "3000" match).
    static func numbers(_ s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\d+(?:[.,]\d+)*"#) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            Range(m.range, in: s).map { r in
                trimmedDecimal(String(s[r]).replacingOccurrences(of: ",", with: ""))
            }
        }
    }

    /// A number's text with its exponent written out: "1.5e-07" is "0.00000015", "1e+20" is "100000000000000000000".
    static func plainDecimal(_ s: String) -> String {
        guard let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }), let exp = Int(s[s.index(after: e)...]) else { return s }
        var m = String(s[..<e])
        let negative = m.hasPrefix("-")
        if negative { m.removeFirst() }
        let parts = m.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(parts[0]), digits = whole + (parts.count > 1 ? String(parts[1]) : "")
        let point = whole.count + exp
        let out: String
        if point <= 0 { out = "0." + String(repeating: "0", count: -point) + digits }
        else if point >= digits.count { out = digits + String(repeating: "0", count: point - digits.count) }
        else { out = String(digits.prefix(point)) + "." + String(digits.dropFirst(point)) }
        return (negative ? "-" : "") + out
    }

    /// A float's text without trailing decimal zeros ("3000.0" is "3000").
    static func trimmedDecimal(_ s: String) -> String {
        var t = s
        if t.contains(".") { while t.hasSuffix("0") { t.removeLast() }; if t.hasSuffix(".") { t.removeLast() } }
        return t
    }

    /// Sentences: split after ".", "!" or "?" followed by a space or the end, and at line breaks (so "1.5" stays whole).
    static func sentences(_ text: String) -> [String] {
        let marked = text.replacingOccurrences(of: #"(?<=[.!?])(\s+|$)|\n+"#, with: "\u{1}", options: .regularExpression)
        return marked.split(separator: "\u{1}").map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasSuffix(".") || $0.hasSuffix("!") || $0.hasSuffix("?") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty }
    }

    /// The sentences of `text` with a comparative word, no hedge and no number that also appears in the evidence
    /// (given figures, engine fact texts and values, sizes set in the change; never raw JSON).
    static func unsupportedComparatives(_ text: String, sources: [String]) -> [String] {
        let evidence = Set(sources.flatMap(numbers))
        return sentences(text).filter { s in
            // A {fact} placeholder is an engine number.
            guard s.range(of: comparativeWords, options: .regularExpression) != nil,
                  s.range(of: hedgeWords, options: .regularExpression) == nil,
                  s.range(of: #"\{[^{}]+\}"#, options: .regularExpression) == nil else { return false }
            return !numbers(s).contains(where: evidence.contains)
        }
    }

    /// The numbers a JSON value holds as numbers (not digits inside keys or ids), as text.
    static func numberLeaves(_ v: Any?) -> [String] {
        switch v {
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID():
            // Integers exactly; a float from its shortest round-trip text ("579.988", "0.1"), with any exponent
            // written out ("1e-07" is "0.0000001"), so it matches the same number in an answer.
            return [CFNumberIsFloatType(n) ? trimmedDecimal(plainDecimal("\(n.doubleValue)")) : n.stringValue]
        case let a as [Any]: return a.flatMap { numberLeaves($0) }
        case let o as [String: Any]: return o.values.flatMap { numberLeaves($0) }
        default: return []
        }
    }

    /// Engine fact texts of a report ("12 teeth", "1/3"): evidence for the answer lint.
    static func factTexts(_ r: [String: Any]?) -> [String] {
        ((r?["facts"] as? [String: Any]) ?? [:]).values.compactMap { ($0 as? [String: Any])?["text"] as? String }
    }

    /// The given figures of a document, for the answer prompt and the lint: unchecked labels and arrows ("text —
    /// source") and the rows of noted explainer tables ("cells — basis or unchecked"). At most 12.
    static func givenFigures(_ document: Any?) -> [String] {
        guard let d = document as? [String: Any] else { return [] }
        var out: [String] = []
        let ann = (d["annotations"] ?? (d["solid"] as? [String: Any])?["annotations"]) as? [String: Any] ?? [:]
        for key in ["labels", "arrows"] {
            for a in ann[key] as? [[String: Any]] ?? [] {
                if let u = a["unchecked"] as? String, let t = a["text"] as? String { out.append("\(t) — \(u) (not checked)") }
            }
        }
        for r in tableRows(d) { out.append(r.row + " — " + r.source + " (" + r.tier + ")" + r.from) }
        return Array(out.prefix(12))
    }

    /// The rows of noted explainer tables, replayed through the beats: the first version of each table, then each
    /// "set" of its cells (marked with the beat it shows from), after any header change. `tier` is "given" (a basis
    /// note) or "not checked" (an unchecked note).
    static func tableRows(_ d: [String: Any]) -> [(row: String, source: String, tier: String, from: String)] {
        let notes = d["notes"] as? [String: Any] ?? [:]
        var versions: [(id: String, beat: Int?, header: Bool, cells: [[Any]])] = []
        var header: [String: Bool] = [:]
        for t in ((d["board"] as? [String: Any])?["items"] as? [[String: Any]]) ?? [] where t["k"] as? String == "table" {
            if let id = t["id"] as? String { header[id] = t["header"] as? Bool == true; versions.append((id, nil, header[id]!, t["cells"] as? [[Any]] ?? [])) }
        }
        for (n, beat) in (d["beats"] as? [[String: Any]] ?? []).enumerated() {
            for case let o as [String: Any] in beat["ops"] as? [Any] ?? [] {
                switch o["op"] as? String {
                case "add":
                    if let t = o["item"] as? [String: Any], t["k"] as? String == "table", let id = t["id"] as? String {
                        header[id] = t["header"] as? Bool == true
                        versions.append((id, n + 1, header[id]!, t["cells"] as? [[Any]] ?? []))
                    }
                case "set":
                    guard let id = o["id"] as? String, let h = header[id] else { break }
                    if o["key"] as? String == "header" { header[id] = o["value"] as? Bool == true }
                    if o["key"] as? String == "cells", let cells = o["value"] as? [[Any]] { versions.append((id, n + 1, h, cells)) }
                default: break
                }
            }
        }
        var out: [(row: String, source: String, tier: String, from: String)] = []
        var first = Set<String>()
        for v in versions {
            guard let note = notes[v.id] as? [String: Any] else { continue }
            let basis = note["basis"] as? String, unchecked = note["unchecked"] as? String
            guard let source = basis ?? unchecked else { continue }
            let from = first.insert(v.id).inserted ? "" : " (from beat \(v.beat.map(String.init) ?? "?"))"
            for row in v.cells.dropFirst(v.header ? 1 : 0) {
                out.append((row.map { "\($0)" }.joined(separator: " "), source, basis != nil ? "given" : "not checked", from))
            }
        }
        return out
    }

    static let maxTextsPerStep = 5

    /// Marty's lint of an engine-accepted document (assembly or explainer): a step or beat that shows more than 5
    /// texts (labels, dimensions and arrows with text), and a caption or label sentence that compares sizes or shares
    /// with no hedge, no {fact} placeholder and no given figure.
    static func documentLint(_ document: Any) -> [String] {
        guard let d = document as? [String: Any] else { return [] }
        let explainer = d["kind"] as? String == "explainer"
        let solid = explainer ? d["solid"] as? [String: Any] ?? [:] : d
        let ann = solid["annotations"] as? [String: Any] ?? [:]
        var texts: [String: String] = [:]
        for l in ann["labels"] as? [[String: Any]] ?? [] { if let id = l["id"] as? String { texts[id] = l["text"] as? String ?? "" } }
        for a in ann["dimensions"] as? [[String: Any]] ?? [] { if let id = a["id"] as? String { texts[id] = a["text"] as? String ?? "" } }
        for a in ann["arrows"] as? [[String: Any]] ?? [] { if let id = a["id"] as? String, let t = a["text"] as? String { texts[id] = t } }
        let steps: [[String: Any]] = explainer ? d["beats"] as? [[String: Any]] ?? [] : d["steps"] as? [[String: Any]] ?? []
        func list(_ step: [String: Any]) -> [String]? { (explainer ? (step["view"] as? [String: Any])?["annotate"] : step["annotate"]) as? [String] }
        let stepped = steps.contains { list($0) != nil }
        var out: [String] = []
        let word = explainer ? "Beat" : "Step"
        for (n, step) in steps.enumerated() {
            // The engine shows each listed id once.
            let shown = Set(stepped ? (list(step) ?? []) : Array(texts.keys))
            let count = shown.filter { texts[$0] != nil }.count
            if count > maxTextsPerStep {
                out.append("\(word) \(n + 1) shows \(count) texts (labels, dimensions and arrows with text); at most \(maxTextsPerStep). An arrow without \"text\" does not count.")
            }
        }
        // Given figures (an unchecked label or arrow whose text shows a typed number, or a noted table row with one):
        // no merged range (a span of years is fine), and a source with a year unless it is "reported", an "assumed
        // example" or a fact table row id ("F3 ..."). An unchecked text with no typed number is a reason, not a source.
        var noted: [(String, String, String)] = []   // (where, shown text, source)
        func typedNumber(_ t: String) -> Bool {
            t.replacingOccurrences(of: #"\{[^{}]*\}"#, with: "", options: .regularExpression).rangeOfCharacter(from: .decimalDigits) != nil
        }
        for key in ["labels", "arrows"] {
            for a in ann[key] as? [[String: Any]] ?? [] {
                if let u = a["unchecked"] as? String, typedNumber(a["text"] as? String ?? "") {
                    noted.append(("Annotation \(a["id"] as? String ?? "?")", a["text"] as? String ?? "", u))
                }
            }
        }
        // Noted table rows (basis or unchecked note) with a typed number (a {fact} cell is the engine's).
        for r in tableRows(d) {
            let typed = r.row.replacingOccurrences(of: #"\{[^{}]*\}"#, with: "", options: .regularExpression)
            if typed.rangeOfCharacter(from: .decimalDigits) != nil { noted.append(("Table row \"\(r.row)\"", r.row, r.source)) }
        }
        for (whereText, shown, source) in noted {
            if hasMergedRange(shown) || hasMergedRange(source) {
                out.append("\(whereText) merges two figures into one range: give each figure with its own source and year.")
            }
            if source.range(of: #"(?i)\b(reported|assumed example|estimate)\b|^F[0-9]{1,2}\b"#, options: .regularExpression) == nil,
               source.range(of: #"\b(1[89]|20)\d\d\b"#, options: .regularExpression) == nil {
                out.append("\(whereText) names a source with no year (\"\(source)\"): add the year, or write \"reported\".")
            }
        }
        let evidence = givenFigures(d)
        let says = steps.enumerated().compactMap { n, s in (s["say"] as? String).map { ("\(word) \(n + 1)", $0) } }
            + texts.sorted { $0.key < $1.key }.map { ("Annotation \($0.key)", $0.value) }
        for (whereText, text) in says {
            for sentence in unsupportedComparatives(text, sources: evidence) {
                out.append("\(whereText) says \"\(sentence)\": a share or comparison needs a given figure or a {fact}, or a hedge (about, in this schematic).")
            }
        }
        return Array(out.prefix(12))
    }

    /// A number range such as "144-155" or "144 to 155" (a span of years such as "2020-2022" is not one).
    static func hasMergedRange(_ text: String) -> Bool {
        // Dates (2024-05-01, 2024-05) are not ranges; a number glued to letters or a dash (A320-200, Mk-4) is an
        // identifier; a trailing period is not a decimal point.
        let plain = text.replacingOccurrences(of: #"\b\d{4}-\d{2}(?:-\d{2})?\b"#, with: " ", options: .regularExpression)
        guard let re = try? NSRegularExpression(pattern: #"(?<![\p{L}\d.,/-])(\d+(?:[.,]\d+)*)\s*(?:–|—|-|\bto\b)\s*(\d+(?:[.,]\d+)*)(?![\d/-])"#)
        else { return false }
        let ns = plain as NSString
        for m in re.matches(in: plain, range: NSRange(location: 0, length: ns.length)) {
            let a = ns.substring(with: m.range(at: 1)), b = ns.substring(with: m.range(at: 2))
            let year = #"^(1[89]|20)\d\d$"#
            if a.range(of: year, options: .regularExpression) != nil, b.range(of: year, options: .regularExpression) != nil { continue }
            return true
        }
        return false
    }

    /// The base document's steps with `step` appended (no `replace`), or put in place of step `replace` (1-based);
    /// nil when `replace` is not the number of an existing step.
    static func stepsWith(_ step: [String: Any], replace: Any?, base docText: String) -> [Any]? {
        var steps = ((try? JSONSerialization.jsonObject(with: Data(docText.utf8))) as? [String: Any])?["steps"] as? [Any] ?? []
        guard let replace, !(replace is NSNull) else { steps.append(step); return steps }
        // A JSON true is an NSNumber that would cast to 1: only a real integer names a step.
        guard let num = replace as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID(), num.doubleValue == num.doubleValue.rounded()
        else { return nil }
        let n = num.intValue
        guard n >= 1, n <= steps.count else { return nil }
        steps[n - 1] = step
        return steps
    }

    /// The authored pose, show and hide of each step (or explainer beat view), for the change summary.
    static func stepViews(_ steps: Any?, beats: Bool = false) -> Data {
        let list = (steps as? [[String: Any]] ?? []).map { s -> [String: Any] in
            let v = beats ? (s["view"] as? [String: Any] ?? [:]) : s
            return ["pose": v["pose"] ?? NSNull(), "show": v["show"] ?? NSNull(), "hide": v["hide"] ?? NSNull()]
        }.filter { $0.values.contains { !($0 is NSNull) } }
        return MartyJSON.data(list)
    }

    /// The engine's effective step views (assembly steps or explainer beats): for each step that poses or hides
    /// parts, its number, the parts posed, the parts hidden and the pose read-back. A pose that moves nothing is not
    /// in it; an added step that poses nothing changes nothing.
    static func effectiveViews(_ report: [String: Any]) -> Data {
        let list = (report["stepViews"] as? [[String: Any]] ?? []).compactMap { v -> [String: Any]? in
            let posed = (v["posed"] as? [String] ?? []).sorted(), hidden = (v["hidden"] as? [String] ?? []).sorted()
            guard !posed.isEmpty || !hidden.isEmpty else { return nil }
            return ["step": v["step"] ?? NSNull(), "posed": posed, "hidden": hidden, "poseReadBack": v["poseReadBack"] ?? []]
        }
        return MartyJSON.data(list)
    }

    /// The parts whose effective placement differs in some step between two reports (posed before or after, and the
    /// parts the pose read-back says move with them), so removing a pose counts as a move too.
    static func viewMovedIds(before: [String: Any], after: [String: Any]) -> Set<String> {
        func byStep(_ r: [String: Any]) -> [Int: [String: Any]] {
            var out: [Int: [String: Any]] = [:]
            for v in r["stepViews"] as? [[String: Any]] ?? [] { if let n = v["step"] as? Int { out[n] = v } }
            return out
        }
        func ids(_ v: [String: Any]?) -> Set<String> {
            guard let v else { return [] }
            let back = (v["poseReadBack"] as? [String] ?? []).compactMap { $0.components(separatedBy: ":").first }
            return Set(v["posed"] as? [String] ?? []).union(back)
        }
        let a = byStep(before), b = byStep(after)
        var out = Set<String>()
        for n in Set(a.keys).union(b.keys) {
            let x = ids(a[n]), y = ids(b[n])
            let same = MartyJSON.data(a[n]?["poseReadBack"] ?? []) == MartyJSON.data(b[n]?["poseReadBack"] ?? [])
            if !same { out.formUnion(x.union(y)) }
        }
        return out
    }

    /// What a follow-up may change in an explainer, without its words: the solid (without label and arrow text), the
    /// board items other than text items, and the beats' model ops in order (an absent or empty ops list adds nothing;
    /// title and camera ops and ops on text items or on a "text" or "label" key are words). A change of words only
    /// (captions, titles, notes, text items, an added caption-only beat) gives the same bytes.
    static func modelContent(_ d: [String: Any]) -> Data {
        MartyJSON.data(["solid": modelSolid(d), "board": modelBoardOther(d), "items": modelBoardItems(d), "ops": modelOps(d)])
    }

    /// The board's keys other than its items and title (template, params, hide, over and the rest are model content).
    static func modelBoardOther(_ d: [String: Any]) -> [String: Any] {
        guard let board = d["board"] as? [String: Any] else { return ["board": d["board"] ?? NSNull()] }
        return board.filter { $0.key != "items" && $0.key != "title" }
    }

    /// A non-text board item without its words (its "label" and "text").
    static func withoutWords(_ item: [String: Any]) -> [String: Any] {
        var o = item; o["label"] = nil; o["text"] = nil; return o
    }

    static func modelSolid(_ d: [String: Any]) -> Any {
        guard var solid = d["solid"] as? [String: Any] else { return d["solid"] ?? NSNull() }
        solid["title"] = nil
        if var ann = solid["annotations"] as? [String: Any] {
            for key in ["labels", "arrows", "dimensions"] {
                if let list = ann[key] as? [[String: Any]] { ann[key] = list.map { var o = $0; o["text"] = nil; return o } }
            }
            solid["annotations"] = ann
        }
        return solid
    }

    static func textItemIds(_ d: [String: Any]) -> Set<String> {
        var ids = Set(((d["board"] as? [String: Any])?["items"] as? [[String: Any]] ?? [])
            .filter { $0["k"] as? String == "text" }.compactMap { $0["id"] as? String })
        for beat in d["beats"] as? [[String: Any]] ?? [] {
            for case let o as [String: Any] in beat["ops"] as? [Any] ?? [] where o["op"] as? String == "add" {
                if let item = o["item"] as? [String: Any], item["k"] as? String == "text", let id = item["id"] as? String { ids.insert(id) }
            }
        }
        return ids
    }

    /// The board items other than text items, by id (an item without an id keeps its place under "#<index>").
    static func modelBoardItems(_ d: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (n, item) in ((d["board"] as? [String: Any])?["items"] as? [[String: Any]] ?? []).enumerated() where item["k"] as? String != "text" {
            out[item["id"] as? String ?? "#\(n)"] = withoutWords(item)
        }
        return out
    }

    static func modelOps(_ d: [String: Any]) -> [Any] {
        let text = textItemIds(d)
        var ops: [Any] = []
        for beat in d["beats"] as? [[String: Any]] ?? [] {
            guard let raw = beat["ops"] else { continue }
            guard let list = raw as? [Any] else { ops.append(raw); continue }
            for op in list {
                guard let o = op as? [String: Any] else { ops.append(op); continue }
                switch o["op"] as? String {
                case "title", "camera": continue
                case "add":
                    if let item = o["item"] as? [String: Any] {
                        if item["k"] as? String == "text" { continue }
                        var w = o; w["item"] = withoutWords(item); ops.append(w); continue
                    }
                case "set", "remove":
                    if let id = o["id"] as? String, text.contains(id) { continue }
                    if let key = o["key"] as? String, key == "text" || key == "label" { continue }
                default: break
                }
                ops.append(o)
            }
        }
        return ops
    }

    /// The accepted change of an explainer follow-up, for the answer prompt, with values before and after: the solid
    /// parts added, changed or removed (by id), other solid keys (params, constraints, annotations), the board items
    /// other than text items, and the beats' model ops.
    static func changeSummary(from base: [String: Any], to new: [String: Any]) -> String {
        func diff(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
            var out: [String: Any] = [:]
            for k in Set(a.keys).union(b.keys).sorted() where MartyJSON.data(a[k] ?? NSNull()) != MartyJSON.data(b[k] ?? NSNull()) {
                out[k] = ["before": a[k] ?? "absent", "after": b[k] ?? "absent"]
            }
            return out
        }
        func parts(_ d: [String: Any]) -> [String: Any] {
            var out: [String: Any] = [:]
            for p in ((d["solid"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []) { if let id = p["id"] as? String { out[id] = p } }
            return out
        }
        var summary: [String: Any] = [:]
        let p = diff(parts(base), parts(new))
        if !p.isEmpty { summary["solid parts"] = p }
        let other = diff((base["solid"] as? [String: Any] ?? [:]).filter { $0.key != "parts" },
                         (new["solid"] as? [String: Any] ?? [:]).filter { $0.key != "parts" })
        if !other.isEmpty { summary["solid other"] = other }
        let board = diff(modelBoardOther(base), modelBoardOther(new))
        if !board.isEmpty { summary["board"] = board }
        let items = diff(modelBoardItems(base), modelBoardItems(new))
        if !items.isEmpty { summary["board items"] = items }
        let opsA = modelOps(base), opsB = modelOps(new)
        if MartyJSON.data(opsA) != MartyJSON.data(opsB) { summary["beat ops"] = ["before": opsA, "after": opsB] }
        let viewsA = stepViews(base["beats"], beats: true), viewsB = stepViews(new["beats"], beats: true)
        if viewsA != viewsB {
            summary["beat views (pose, show, hide)"] = ["before": (try? JSONSerialization.jsonObject(with: viewsA)) ?? [],
                                                        "after": (try? JSONSerialization.jsonObject(with: viewsB)) ?? []]
        }
        return MartyJSON.string(summary)
    }

    /// The force arrows without a checked cause (not gravity) that a change may have moved or turned: an arrow with an
    /// end (or its "on" part) on a moved part or on a part hung below one, and an arrow whose definition changed. With
    /// `all` (the change touched params, constraints or joints) every such arrow counts. The engine checks a gravity
    /// arrow again in the changed model, so it is never listed.
    static func movedForceArrows(annotations: Any?, parts: [[String: Any]], moved: Set<String>, all: Bool,
                                 changedArrows: Set<String> = []) -> [String] {
        // An inner-part edit ("pilot.upperArmL") can move every part of that component instance (its hierarchy is not
        // in the document), so the whole instance counts as moved.
        var m = moved.union(moved.compactMap { $0.split(separator: ".").first.map(String.init) })
        func hit(_ ref: String) -> Bool { m.contains(ref) || m.contains { ref.hasPrefix($0 + ".") } }
        var grew = true
        while grew {
            grew = false
            for p in parts {
                guard let id = p["id"] as? String, !hit(id), let parent = p["parent"] as? String, hit(parent) else { continue }
                m.insert(id); grew = true
            }
        }
        func ref(_ a: Any?) -> String? { (a as? String) ?? ((a as? [String: Any])?["part"] as? String) }
        let arrows = (annotations as? [String: Any])?["arrows"] as? [[String: Any]] ?? []
        return arrows.compactMap { a in
            guard a["meaning"] as? String == "force", a["cause"] as? String != "gravity", let id = a["id"] as? String else { return nil }
            if all || changedArrows.contains(id) { return id }
            return [a["from"], a["to"], a["on"]].compactMap(ref).contains(where: hit) ? id : nil
        }
    }

    /// The force arrows that an accepted explainer change may have moved: the solid parts it added or changed, every
    /// arrow when other model keys of the solid changed, and the arrows whose definition changed.
    static func movedForceArrows(explainerFrom base: [String: Any], to new: [String: Any], viewMoved: Set<String> = []) -> [String] {
        let a = base["solid"] as? [String: Any] ?? [:], b = new["solid"] as? [String: Any] ?? [:]
        func byId(_ list: Any?) -> [String: Data] {
            var out: [String: Data] = [:]
            for o in list as? [[String: Any]] ?? [] { if let id = o["id"] as? String { out[id] = MartyJSON.data(o) } }
            return out
        }
        let pa = byId(a["parts"]), pb = byId(b["parts"])
        let movedParts = Set(pb.keys.filter { pa[$0] != pb[$0] }).union(pa.keys.filter { pb[$0] == nil })
            .union(viewMoved)
        let aa = byId((a["annotations"] as? [String: Any])?["arrows"]), ab = byId((b["annotations"] as? [String: Any])?["arrows"])
        let words: Set<String> = ["parts", "annotations", "title", "steps"]
        let all = Set(a.keys).union(b.keys).subtracting(words).contains { MartyJSON.data(a[$0] ?? NSNull()) != MartyJSON.data(b[$0] ?? NSNull()) }
        return movedForceArrows(annotations: b["annotations"], parts: b["parts"] as? [[String: Any]] ?? [], moved: movedParts,
                                all: all, changedArrows: Set(ab.keys.filter { aa[$0] != ab[$0] }))
    }

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
    public static let formatExample = #"{"v":2,"kind":"assembly","title":"A shaft held in two bearings","units":"mm","parts":[{"id":"base","use":"housingBase","at":[0,0,-1]},{"id":"shaft","use":"shaftWithBearing","with":{"radius":6,"length":80}}],"annotations":{"labels":[{"id":"lShaft","at":{"part":"shaft.input","offset":[0,-6,40]},"text":"Shaft"},{"id":"lRated","at":{"world":[0,-70,20]},"text":"Rated 3000 rpm","unchecked":"assumed example"}],"arrows":[{"id":"aW","meaning":"force","cause":"gravity","from":{"part":"base.base","offset":[0,0,-80]},"to":{"part":"base.base","offset":[0,0,-120]},"text":"Weight"}]},"steps":[{"say":"Two bearings hold a shaft in line on a base.","camera":"hero","annotate":["lShaft","lRated","aW"]},{"say":"Input: the shaft makes {shaft.input.speed} turn for each input turn.","highlight":["shaft.input"],"spin":1,"check":[{"value":"shaft.input.speed","eq":1}],"annotate":["lShaft"]},{"say":"Cut open: the lower bearing rings the shaft.","section":{"normal":[0,-1,0],"parts":["shaft.lowerBearing"]},"highlight":["shaft.lowerBearing"],"focus":["shaft.lowerBearing","shaft.shaft"],"annotate":[]},{"say":"Seen through the base.","ghost":["base.base"],"annotate":["aW"]}]}"#
    /// A small explainer: the same shaft with a table of one given number (with its source) and one engine fact.
    public static let explainerExample = #"{"v":1,"kind":"explainer","title":"A shaft held in two bearings","primary":"solid","notes":{"t":{"basis":"F1 maker's data sheet, 2024, claimed"}},"board":{"v":1,"items":[{"id":"cap","k":"text","at":[6,7],"text":"Key figures"}]},"solid":{"v":2,"parts":[{"id":"base","use":"housingBase","at":[0,0,-1]},{"id":"shaft","use":"shaftWithBearing","with":{"radius":6,"length":80}}],"annotations":{"arrows":[{"id":"aW","meaning":"force","cause":"gravity","from":{"part":"base.base","offset":[0,0,-80]},"to":{"part":"base.base","offset":[0,0,-120]},"text":"Weight"}]}},"beats":[{"say":"Two bearings hold a shaft on a base; the table gives its rated speed.","highlight":["t.r1","shaft.shaft"],"ops":[{"op":"add","item":{"id":"t","k":"table","at":[6,4],"header":true,"cells":[["Item","Value"],["Rated rpm",3000],["Turns/input","{shaft.input.speed}"]]}}],"view":{"annotate":["aW"]}},{"say":"Cut open: the lower bearing rings the shaft.","highlight":["shaft.lowerBearing"],"view":{"section":{"normal":[0,-1,0],"parts":["shaft.lowerBearing"]},"focus":["shaft.lowerBearing","shaft.shaft"],"annotate":[]}}]}"#
}
