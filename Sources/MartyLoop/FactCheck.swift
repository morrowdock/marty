// SPDX-License-Identifier: Apache-2.0
import Foundation
import MartyEngine

/// `fact.unsourced.<field>`: every typed number, year and product version in the text of a document (or a follow-up
/// patch) must come from the evidence: the fact table (values, claims, versions, source dates), the question, the
/// engine's own facts and ratios, and the sizes set in the model itself. Engine placeholders ({fact}), row ids (F3) and
/// "2D"/"3D" are not facts. A part name is checked for years and versions only (it may count units: "Jet 2").
@MainActor public enum FactCheck {
    public struct Finding: Equatable {
        public let field: String
        public let token: String
        public var line: String { "\(field): \"\(token)\" is not in the fact table, the question or the model" }
    }

    /// The evidence tokens: numbers (normalized as in `MartyLoop.numbers`) and lower-case version tokens.
    public struct Evidence {
        public var numbers: Set<String>
        public var versions: Set<String>
        public init(numbers: Set<String> = [], versions: Set<String> = []) { self.numbers = numbers; self.versions = versions }

        @MainActor public static func build(table: FactTable, question: String, report: [String: Any]?, model: Any?, extra: [String] = []) -> Evidence {
            var texts = [question] + extra
            for r in table.rows {
                texts += [r.claim, r.value, r.appliesTo] + r.sources.map(\.date)
            }
            texts += MartyLoop.factTexts(report)
            var nums = Set(texts.flatMap(MartyLoop.numbers))
            nums.formUnion(MartyLoop.numberLeaves(report?["ratios"]).flatMap(MartyLoop.numbers))
            // A solved value may also be written as its exact fraction or its inverse (the engine's frac and inv).
            let solved = MartyLoop.numberLeaves(report?["ratios"])
                + ((report?["facts"] as? [String: Any]) ?? [:]).values.flatMap { MartyLoop.numberLeaves(($0 as? [String: Any])?["value"]) }
            for v in solved.compactMap(Double.init) where v != 0 {
                for (p, q) in [fraction(abs(v)), fraction(1 / abs(v))].compactMap({ $0 }) { nums.insert(String(p)); nums.insert(String(q)) }
                nums.formUnion(MartyLoop.numbers(MartyLoop.trimmedDecimal(String(format: "%.2f", 1 / abs(v)))))
            }
            nums.formUnion(sizes(model).flatMap(MartyLoop.numbers))
            return Evidence(numbers: nums, versions: Set(texts.flatMap(FactCheck.versions)))
        }
    }

    /// The exact fraction p/q of `v` (q at most 1000), or nil.
    static func fraction(_ v: Double) -> (Int, Int)? {
        guard v.isFinite, v > 0, v < 1e12, v > 1e-12 else { return nil }
        for q in 1...1000 {
            let p = (v * Double(q)).rounded()
            guard p < 1e15 else { return nil }
            if p >= 1, abs(p / Double(q) - v) < 1e-9 * max(1, v) { return (Int(p), q) }
        }
        return nil
    }

    /// Numbers set in the model: every number in parts, params and constraints (and a solid's), not in text fields.
    static func sizes(_ model: Any?) -> [String] {
        guard let d = model as? [String: Any] else { return [] }
        var out: [String] = []
        for key in ["parts", "params", "constraints"] { out += MartyLoop.numberLeaves(d[key]) }
        if let solid = d["solid"] { out += sizes(solid) }
        return out
    }

    /// Version tokens: "Mk 4" / "Mark IV" and "Gen 3" in any case, "v2" written together, and "Model 3", "Series 5",
    /// "Version 2" only capitalized and not at the start of a sentence (so "the model 3 times" is prose). Lower case,
    /// single spaces.
    static func versions(_ text: String) -> [String] {
        var out: [String] = []
        let ns = text as NSString
        func scan(_ pattern: String, _ keep: (NSTextCheckingResult) -> Bool = { _ in true }) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where keep(m) {
                var kind = ns.substring(with: m.range(at: 1)).lowercased().replacingOccurrences(of: ".", with: "")
                if kind == "mark" { kind = "mk" }
                if kind == "generation" { kind = "gen" }
                if kind == "version" { kind = "v" }
                out.append(kind + " " + ns.substring(with: m.range(at: 2)).lowercased())
            }
        }
        scan(#"(?i)\b(mk\.?|mark|gen|generation)\s?([0-9]+(?:\.[0-9]+)*|[ivx]{1,5})\b"#)
        scan(#"\b([vV])([0-9]+(?:\.[0-9]+)*)\b"#)
        scan(#"\b(Model|Series|Version)\s([0-9]+(?:\.[0-9]+)*|[IVX]{1,5})\b"#) { m in
            let before = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
            return !(before.isEmpty || before.hasSuffix(".") || before.hasSuffix("!") || before.hasSuffix("?") || before.hasSuffix(":"))
        }
        return out
    }

    static let years = #"\b(1[89][0-9]{2}|20[0-9]{2})\b"#

    /// An engine placeholder: `{name}` or `{name|mod|mod}` with a fact name.
    static let placeholder = #"\{[A-Za-z_][A-Za-z0-9_.]*(?:\|[a-z]+)*\}"#

    /// The text without row ids and "2D"/"3D", and without engine placeholders where the engine fills them
    /// (`placeholders`: v2 assemblies and explainers; v1 text and answers show braces as typed).
    static func plain(_ text: String, placeholders: Bool = true) -> String {
        (placeholders ? text.replacingOccurrences(of: placeholder, with: " ", options: .regularExpression) : text)
            .replacingOccurrences(of: #"\bF[0-9]{1,2}\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b[23]D\b"#, with: " ", options: .regularExpression)
    }

    /// The findings of one text field. `namesOnly`: years and versions only.
    static func check(_ field: String, _ text: String, _ e: Evidence, namesOnly: Bool = false, placeholders: Bool = true) -> [Finding] {
        let t = plain(text, placeholders: placeholders)
        var out: [Finding] = []
        for v in versions(t) where !e.versions.contains(v) { out.append(Finding(field: field, token: v)) }
        let tokens = namesOnly
            ? MartyLoop.numbers(t).filter { $0.range(of: #"^(1[89][0-9]{2}|20[0-9]{2})$"#, options: .regularExpression) != nil }
            : MartyLoop.numbers(t)
        // A number inside a version token is checked as the version.
        let versionNumbers = Set(versions(t).compactMap { $0.split(separator: " ").last.map(String.init) })
        for n in tokens where !e.numbers.contains(n) && !versionNumbers.contains(n) {
            out.append(Finding(field: field, token: n))
        }
        return out
    }

    /// The keys of a 2D item that are shown as text or numbers (MGParser.allowedKeys at the pin).
    static let shownKeys: Set<String> = ["text", "label", "xl", "yl", "cells", "bars", "unit", "vals", "ptrs", "xr", "yr"]

    /// The text fields of an assembly (v1 or v2), an explainer or a follow-up patch, with their field names.
    static func fields(_ d: [String: Any]) -> [(field: String, text: String, namesOnly: Bool)] {
        // (The engine fills placeholders in v2 assemblies and explainers; see `findings`.)
        var out: [(String, String, Bool)] = []
        func add(_ f: String, _ v: Any?, namesOnly: Bool = false) {
            if let s = v as? String, !s.isEmpty { out.append((f, s, namesOnly)) }
            else if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { out.append((f, "\(n)", namesOnly)) }
        }
        func annotations(_ a: Any?) {
            guard let a = a as? [String: Any] else { return }
            for key in ["labels", "arrows", "dimensions"] {
                for x in a[key] as? [[String: Any]] ?? [] {
                    let id = x["id"] as? String ?? "?"
                    // A number labelled "assumed example" is an example, not a fact (it shows as Not checked).
                    if ((x["unchecked"] as? String) ?? "").lowercased().hasPrefix("assumed example") { continue }
                    add("annotation.\(id)", x["text"]); add("annotation.\(id).unchecked", x["unchecked"])
                }
            }
        }
        func parts(_ p: Any?, prefix: String = "") {
            if let list = p as? [[String: Any]] {
                for x in list { add("\(prefix)part.\(x["id"] as? String ?? "?").name", x["name"], namesOnly: true) }
            } else if let map = p as? [String: Any] {   // a patch: {"<id>": {fields}}
                for (id, x) in map { add("\(prefix)part.\(id).name", (x as? [String: Any])?["name"], namesOnly: true) }
            }
        }
        // Every value a 2D item shows (as text or as a number), by key; nested colours and positions are not shown.
        func shown(_ f: String, _ v: Any?) {
            switch v {
            case let list as [Any]: for (n, x) in list.enumerated() { shown("\(f)[\(n)]", x) }
            case let o as [String: Any]: for (k, x) in o where !["color", "at", "id", "k", "i"].contains(k) { shown("\(f).\(k)", x) }
            default: add(f, v)
            }
        }
        func board(_ item: [String: Any], _ where_: String) {
            let id = item["id"] as? String ?? "?"
            for key in shownKeys where key != "cells" { shown("\(where_)\(id).\(key)", item[key]) }
            for (r, row) in (item["cells"] as? [[Any]] ?? []).enumerated() {
                for (c, cell) in row.enumerated() { add("\(where_)\(id).r\(r)c\(c)", cell) }
            }
        }
        // A one-key edit ("set" or a board "over" entry) is checked only when the key is shown.
        func edit(_ id: String, _ key: String, _ value: Any?, _ where_: String) {
            guard shownKeys.contains(key) else { return }
            if key == "cells", let cells = value as? [[Any]] { board(["id": id, "cells": cells], where_) }
            else { shown("\(where_)\(id).\(key)", value) }
        }
        add("title", d["title"])
        parts(d["parts"])
        annotations(d["annotations"])
        for (n, s) in (d["steps"] as? [[String: Any]] ?? []).enumerated() {
            add("step\(n + 1).say", s["say"]); add("step\(n + 1).unchecked", s["unchecked"])
        }
        if let solid = d["solid"] as? [String: Any] {
            add("solid.title", solid["title"])
            parts(solid["parts"], prefix: "solid.")
            annotations(solid["annotations"])
        }
        let boardDoc = d["board"] as? [String: Any] ?? [:]
        add("board.title", boardDoc["title"])
        for item in boardDoc["items"] as? [[String: Any]] ?? [] { board(item, "board.") }
        for o in boardDoc["over"] as? [[String: Any]] ?? [] {
            if let id = o["id"] as? String, let key = o["key"] as? String { edit(id, key, o["value"], "board.over.") }
        }
        for (id, note) in d["notes"] as? [String: Any] ?? [:] {
            add("note.\(id).basis", (note as? [String: Any])?["basis"]); add("note.\(id).unchecked", (note as? [String: Any])?["unchecked"])
        }
        for (n, b) in (d["beats"] as? [[String: Any]] ?? []).enumerated() {
            add("beat\(n + 1).say", b["say"]); add("beat\(n + 1).unchecked", b["unchecked"])
            for case let o as [String: Any] in b["ops"] as? [Any] ?? [] {
                if let item = o["item"] as? [String: Any] { board(item, "beat\(n + 1).") }
                if o["op"] as? String == "set", let id = o["id"] as? String, let key = o["key"] as? String {
                    edit(id, key, o["value"], "beat\(n + 1).")
                }
                if o["op"] as? String == "title" { add("beat\(n + 1).title", o["title"]) }
                if o["op"] as? String == "bind" { add("beat\(n + 1).control.label", (o["control"] as? [String: Any])?["label"]) }
            }
        }
        return out
    }

    /// All findings of a document or patch, in field order, at most `limit`.
    public static func findings(_ document: Any, evidence: Evidence, limit: Int = 12) -> [Finding] {
        guard let d = document as? [String: Any] else { return [] }
        // A v1 assembly shows "{...}" as typed text; v2 assemblies, explainers and patches of v2 documents fill it.
        let filled = !(d["v"] as? Int == 1 && d["kind"] as? String == "assembly")
        var out: [Finding] = []
        for f in fields(d) {
            for x in check(f.field, f.text, evidence, namesOnly: f.namesOnly, placeholders: filled) where !out.contains(x) { out.append(x) }
            if out.count >= limit { break }
        }
        return Array(out.prefix(limit))
    }

    /// The reason for a refusal: `fact.unsourced.<field>` of the first finding.
    public static func reason(_ f: [Finding]) -> String? { f.first.map { "fact.unsourced.\($0.field)" } }
}
