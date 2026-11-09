// SPDX-License-Identifier: Apache-2.0
import Foundation
import MartyEngine

/// The length budget of a document's texts (the engine's limits, `MartyTextLimits`): which fields are over their
/// limit, by how much, and a trimmed copy for the engine check. A field that counts after `{fact}` placeholders are
/// filled (labels, arrow texts, explainer titles) is measured with each placeholder as its engine text when the
/// facts are known, else as 8 characters.
@MainActor public enum TextBudget {
    public struct Issue: Equatable {
        public let path: String, limit: Int, actual: Int
        public var line: String { "\(path): \(actual) characters, the limit is \(limit)" }
    }

    /// A text field: its path, its key path in the document, its limit, and whether placeholders are filled.
    struct Field { let path: String; let keys: [Any]; let limit: Int; let filled: Bool }

    static func fields(_ d: [String: Any]) -> [Field] {
        typealias L = MartyTextLimits
        var out: [Field] = []
        let explainer = d["kind"] as? String == "explainer"
        out.append(Field(path: "title", keys: ["title"], limit: explainer ? L.explainerTitle : L.title, filled: explainer))
        func solid(_ s: [String: Any], _ prefix: String, _ base: [Any]) {
            for (n, p) in (s["parts"] as? [[String: Any]] ?? []).enumerated() where p["name"] != nil {
                out.append(Field(path: "\(prefix)parts[\(p["id"] as? String ?? "\(n)")].name", keys: base + ["parts", n, "name"], limit: L.partName, filled: false))
            }
            let ann = s["annotations"] as? [String: Any] ?? [:]
            for key in ["labels", "arrows", "dimensions"] {
                for (n, a) in (ann[key] as? [[String: Any]] ?? []).enumerated() {
                    let id = a["id"] as? String ?? "\(n)"
                    if a["text"] != nil { out.append(Field(path: "\(prefix)\(key)[\(id)].text", keys: base + ["annotations", key, n, "text"], limit: L.annotationText, filled: true)) }
                    if a["unchecked"] != nil { out.append(Field(path: "\(prefix)\(key)[\(id)].unchecked", keys: base + ["annotations", key, n, "unchecked"], limit: L.unchecked, filled: false)) }
                }
            }
        }
        if explainer {
            if let s = d["solid"] as? [String: Any] { solid(s, "solid.", ["solid"]) }
            for (n, b) in (d["beats"] as? [[String: Any]] ?? []).enumerated() {
                if b["say"] != nil { out.append(Field(path: "beats[\(n + 1)].say", keys: ["beats", n, "say"], limit: L.beatSay, filled: false)) }
                if b["unchecked"] != nil { out.append(Field(path: "beats[\(n + 1)].unchecked", keys: ["beats", n, "unchecked"], limit: L.unchecked, filled: false)) }
            }
            for (id, note) in d["notes"] as? [String: Any] ?? [:] {
                for k in ["basis", "unchecked"] where (note as? [String: Any])?[k] != nil {
                    out.append(Field(path: "notes[\(id)].\(k)", keys: ["notes", id, k], limit: L.note, filled: false))
                }
            }
        } else {
            solid(d, "", [])
            for (n, s) in (d["steps"] as? [[String: Any]] ?? []).enumerated() {
                if s["say"] != nil { out.append(Field(path: "steps[\(n + 1)].say", keys: ["steps", n, "say"], limit: L.stepSay, filled: false)) }
                if s["unchecked"] != nil { out.append(Field(path: "steps[\(n + 1)].unchecked", keys: ["steps", n, "unchecked"], limit: L.unchecked, filled: false)) }
            }
        }
        return out
    }

    static func get(_ d: Any, _ keys: [Any]) -> Any? {
        var cur: Any? = d
        for k in keys {
            if let s = k as? String { cur = (cur as? [String: Any])?[s] } else if let i = k as? Int { cur = (cur as? [Any]).flatMap { i < $0.count ? $0[i] : nil } }
        }
        return cur
    }

    static func set(_ d: inout Any, _ keys: [Any], _ value: Any) {
        guard let k = keys.first else { d = value; return }
        let rest = Array(keys.dropFirst())
        if let s = k as? String, var o = d as? [String: Any] {
            var child: Any = o[s] ?? NSNull(); set(&child, rest, value); o[s] = child; d = o
        } else if let i = k as? Int, var a = d as? [Any], i < a.count {
            var child = a[i]; set(&child, rest, value); a[i] = child; d = a
        }
    }

    /// The length of `text` as the engine counts it: Unicode scalars, with placeholders filled from `facts` (name: text)
    /// or counted as 8 characters when `filled` and the fact is unknown.
    static func length(_ text: String, filled: Bool, facts: [String: String]) -> Int {
        guard filled else { return text.unicodeScalars.count }
        guard let re = try? NSRegularExpression(pattern: #"\{([A-Za-z_][A-Za-z0-9_.]*)(?:\|[a-z]+)*\}"#) else { return text.unicodeScalars.count }
        let ns = text as NSString
        var n = text.unicodeScalars.count
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let whole = ns.substring(with: m.range), name = ns.substring(with: m.range(at: 1))
            n += (facts[name]?.unicodeScalars.count ?? 8) - whole.unicodeScalars.count
        }
        return n
    }

    /// The fields over their limit.
    public static func issues(_ document: Any, facts: [String: String] = [:]) -> [Issue] {
        guard let d = document as? [String: Any] else { return [] }
        return fields(d).compactMap { f in
            guard let t = get(d, f.keys) as? String else { return nil }
            let n = length(t, filled: f.filled, facts: facts)
            return n > f.limit ? Issue(path: f.path, limit: f.limit, actual: n) : nil
        }
    }

    /// A copy with each over-long field cut at the last word boundary that fits (never inside a placeholder), when the
    /// cut keeps at least 60 % of the text; the paths it cut. A field that would lose more is left for the repair.
    public static func trimmed(_ document: Any, facts: [String: String] = [:]) -> (document: Any, trimmed: [String]) {
        guard let d = document as? [String: Any] else { return (document, []) }
        var out: Any = d
        var cut: [String] = []
        for f in fields(d) {
            guard let t = get(d, f.keys) as? String, length(t, filled: f.filled, facts: facts) > f.limit else { continue }
            let words = t.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            var kept: [String] = []
            for w in words {
                let next = (kept + [w]).joined(separator: " ")
                if length(next, filled: f.filled, facts: facts) > f.limit { break }
                kept.append(w)
            }
            var s = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            // Never end inside a placeholder or on a dangling joiner.
            if s.filter({ $0 == "{" }).count != s.filter({ $0 == "}" }).count { continue }
            while let last = s.split(separator: " ").last, ["and", "or", "the", "a", "an", "of", "to", "with", "while", ",", "-"].contains(last.lowercased()) {
                s = String(s.dropLast(last.count)).trimmingCharacters(in: .whitespaces)
            }
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: ",;:- "))
            guard !s.isEmpty, s.unicodeScalars.count * 10 >= t.unicodeScalars.count * 6 else { continue }
            if !(s.hasSuffix(".") || s.hasSuffix("!") || s.hasSuffix("?")), t.trimmingCharacters(in: .whitespaces).hasSuffix(".") { s += "." }
            guard length(s, filled: f.filled, facts: facts) <= f.limit else { continue }
            set(&out, f.keys, s)
            cut.append(f.path)
        }
        return (out, cut)
    }
}
