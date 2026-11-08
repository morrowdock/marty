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
        guard v.isFinite, v > 0 else { return nil }
        for q in 1...1000 {
            let p = (v * Double(q)).rounded()
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

    /// Version tokens: "Mk 4", "Mark IV", "v2.1", "Gen 3", "Series 5", "Model 3" (lower case, single spaces).
    static func versions(_ text: String) -> [String] {
        let pattern = #"(?i)\b(mk\.?|mark|gen|generation|series|model|version|v)\s?([0-9]+(?:\.[0-9]+)*|[ivx]{1,5})\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            var kind = ns.substring(with: m.range(at: 1)).lowercased().replacingOccurrences(of: ".", with: "")
            if kind == "mark" { kind = "mk" }
            if kind == "generation" { kind = "gen" }
            if kind == "version" { kind = "v" }
            return kind + " " + ns.substring(with: m.range(at: 2)).lowercased()
        }
    }

    static let years = #"\b(1[89][0-9]{2}|20[0-9]{2})\b"#

    /// The text without engine placeholders, row ids and "2D"/"3D".
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"\{[^{}]*\}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\bF[0-9]{1,2}\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b[23]D\b"#, with: " ", options: .regularExpression)
    }

    /// The findings of one text field. `namesOnly`: years and versions only.
    static func check(_ field: String, _ text: String, _ e: Evidence, namesOnly: Bool = false) -> [Finding] {
        let t = plain(text)
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

    /// The text fields of an assembly (v1 or v2), an explainer or a follow-up patch, with their field names.
    static func fields(_ d: [String: Any]) -> [(field: String, text: String, namesOnly: Bool)] {
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
        func board(_ item: [String: Any], _ where_: String) {
            let id = item["id"] as? String ?? "?"
            add("\(where_)\(id).text", item["text"]); add("\(where_)\(id).label", item["label"])
            for (r, row) in (item["cells"] as? [[Any]] ?? []).enumerated() {
                for (c, cell) in row.enumerated() { add("\(where_)\(id).r\(r)c\(c)", cell) }
            }
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
        for item in (d["board"] as? [String: Any])?["items"] as? [[String: Any]] ?? [] { board(item, "board.") }
        for (id, note) in d["notes"] as? [String: Any] ?? [:] {
            add("note.\(id).basis", (note as? [String: Any])?["basis"]); add("note.\(id).unchecked", (note as? [String: Any])?["unchecked"])
        }
        for (n, b) in (d["beats"] as? [[String: Any]] ?? []).enumerated() {
            add("beat\(n + 1).say", b["say"]); add("beat\(n + 1).unchecked", b["unchecked"])
            for case let o as [String: Any] in b["ops"] as? [Any] ?? [] {
                if let item = o["item"] as? [String: Any] { board(item, "beat\(n + 1).") }
                if o["op"] as? String == "set", let id = o["id"] as? String {
                    if let cells = o["value"] as? [[Any]] { board(["id": id, "cells": cells], "beat\(n + 1).") }
                    else { add("beat\(n + 1).\(id).\(o["key"] as? String ?? "value")", o["value"]) }
                }
                if o["op"] as? String == "title" { add("beat\(n + 1).title", o["title"]) }
            }
        }
        return out
    }

    /// All findings of a document or patch, in field order, at most `limit`.
    public static func findings(_ document: Any, evidence: Evidence, limit: Int = 12) -> [Finding] {
        guard let d = document as? [String: Any] else { return [] }
        var out: [Finding] = []
        for f in fields(d) {
            for x in check(f.field, f.text, evidence, namesOnly: f.namesOnly) where !out.contains(x) { out.append(x) }
            if out.count >= limit { break }
        }
        return Array(out.prefix(limit))
    }

    /// The reason for a refusal: `fact.unsourced.<field>` of the first finding.
    public static func reason(_ f: [Finding]) -> String? { f.first.map { "fact.unsourced.\($0.field)" } }
}
