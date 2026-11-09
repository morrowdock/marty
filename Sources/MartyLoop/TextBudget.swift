// SPDX-License-Identifier: Apache-2.0
import Foundation
import MartyEngine

/// The length budget of a document's texts (the engine's limits at the pin, `MartyTextLimits`). A text has an
/// authored cap (as written) and, where the engine fills `{fact}` placeholders, a filled cap. Marty only states what
/// is certain: the authored length exactly, and for a filled cap a lower bound (each placeholder at least 1
/// character). It cuts only texts without placeholders, whose length is exact; a text with placeholders is left for
/// the repair.
@MainActor public enum TextBudget {
    public struct Issue: Equatable {
        public let path: String, limit: Int, actual: Int
        /// true: `actual` is a lower bound of the filled length.
        public let atLeast: Bool
        public var line: String {
            atLeast ? "\(path): at least \(actual) characters once placeholders are filled, the limit is \(limit)"
                : "\(path): \(actual) characters, the limit is \(limit)"
        }
    }

    /// A text field: its path, its key path in the document, its authored cap and its filled cap (nil when the
    /// engine does not fill placeholders there).
    struct Field {
        let path: String; let keys: [Any]; let authored: Int; let filled: Int?
        /// Whether the engine strips surrounding white space before filling (all filled fields except the explainer
        /// title, which it fills as authored).
        var strips = true
    }

    static func fields(_ d: [String: Any]) -> [Field] {
        typealias L = MartyTextLimits
        var out: [Field] = []
        let explainer = d["kind"] as? String == "explainer"
        let v2 = explainer || (d["v"] as? Int ?? 2) >= 2
        if explainer { out.append(Field(path: "title", keys: ["title"], authored: L.explainerTitleRaw, filled: L.explainerTitle, strips: false)) }
        else { out.append(Field(path: "title", keys: ["title"], authored: L.title, filled: v2 ? L.title : nil)) }
        func solid(_ s: [String: Any], _ prefix: String, _ base: [Any]) {
            if let list = s["parts"] as? [[String: Any]] {
                for (n, p) in list.enumerated() where p["name"] != nil {
                    out.append(Field(path: "\(prefix)parts[\(p["id"] as? String ?? "\(n)")].name", keys: base + ["parts", n, "name"], authored: L.partName, filled: nil))
                }
            } else if let map = s["parts"] as? [String: Any] {   // a follow-up patch: {"<id>": {fields}}
                for (id, p) in map where (p as? [String: Any])?["name"] != nil {
                    out.append(Field(path: "\(prefix)parts[\(id)].name", keys: base + ["parts", id, "name"], authored: L.partName, filled: nil))
                }
            }
            let ann = s["annotations"] as? [String: Any] ?? [:]
            for key in ["labels", "arrows", "dimensions"] {
                for (n, a) in (ann[key] as? [[String: Any]] ?? []).enumerated() {
                    let id = a["id"] as? String ?? "\(n)"
                    if a["text"] != nil { out.append(Field(path: "\(prefix)\(key)[\(id)].text", keys: base + ["annotations", key, n, "text"], authored: L.annotationRaw, filled: L.annotationText)) }
                    if a["unchecked"] != nil { out.append(Field(path: "\(prefix)\(key)[\(id)].unchecked", keys: base + ["annotations", key, n, "unchecked"], authored: L.unchecked, filled: nil)) }
                }
            }
        }
        if explainer {
            if let s = d["solid"] as? [String: Any] { solid(s, "solid.", ["solid"]) }
            for (n, b) in (d["beats"] as? [[String: Any]] ?? []).enumerated() {
                if b["say"] != nil { out.append(Field(path: "beats[\(n + 1)].say", keys: ["beats", n, "say"], authored: L.beatSay, filled: nil)) }
                if b["unchecked"] != nil { out.append(Field(path: "beats[\(n + 1)].unchecked", keys: ["beats", n, "unchecked"], authored: L.unchecked, filled: nil)) }
            }
            for (id, note) in d["notes"] as? [String: Any] ?? [:] {
                for k in ["basis", "unchecked"] where (note as? [String: Any])?[k] != nil {
                    out.append(Field(path: "notes[\(id)].\(k)", keys: ["notes", id, k], authored: L.note, filled: nil))
                }
            }
        } else {
            solid(d, "", [])
            for (n, s) in (d["steps"] as? [[String: Any]] ?? []).enumerated() {
                if s["say"] != nil { out.append(Field(path: "steps[\(n + 1)].say", keys: ["steps", n, "say"], authored: L.stepSay, filled: v2 ? L.stepSay : nil)) }
                if s["unchecked"] != nil { out.append(Field(path: "steps[\(n + 1)].unchecked", keys: ["steps", n, "unchecked"], authored: L.unchecked, filled: nil)) }
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

    static let placeholder = #"\{[A-Za-z_][A-Za-z0-9_.]*(?:\|[a-z]+)*\}"#
    static func hasPlaceholder(_ t: String) -> Bool { t.range(of: placeholder, options: .regularExpression) != nil }

    /// The smallest filled length: the text as the engine keeps it (surrounding white space removed), each
    /// placeholder at least 1 character.
    static func filledAtLeast(_ t: String, strips: Bool = true) -> Int {
        (strips ? t.trimmingCharacters(in: .whitespacesAndNewlines) : t)
            .replacingOccurrences(of: placeholder, with: "x", options: .regularExpression).unicodeScalars.count
    }

    /// The fields certainly over a limit: the authored length over the authored cap, or (filled fields with
    /// placeholders) the lower bound over the filled cap; a field without placeholders is exact against both.
    public static func issues(_ document: Any) -> [Issue] {
        guard let d = document as? [String: Any] else { return [] }
        return fields(d).compactMap { f in
            guard let t = get(d, f.keys) as? String else { return nil }
            let n = t.unicodeScalars.count
            if n > f.authored { return Issue(path: f.path, limit: f.authored, actual: n, atLeast: false) }
            if let cap = f.filled {
                if !hasPlaceholder(t) {
                    let kept = (f.strips ? t.trimmingCharacters(in: .whitespacesAndNewlines) : t).unicodeScalars.count
                    return kept > cap ? Issue(path: f.path, limit: cap, actual: kept, atLeast: false) : nil
                }
                let low = filledAtLeast(t, strips: f.strips)
                return low > cap ? Issue(path: f.path, limit: cap, actual: low, atLeast: true) : nil
            }
            return nil
        }
    }

    /// A copy with each over-long text that has no placeholder cut at the last word that fits, when at least 60 % of
    /// it stays; the paths it cut. Texts with placeholders, and cuts that would lose more, are left for the repair.
    public static func trimmed(_ document: Any) -> (document: Any, trimmed: [String]) {
        guard let d = document as? [String: Any] else { return (document, []) }
        var out: Any = d
        var cut: [String] = []
        for f in fields(d) {
            let limit = min(f.authored, f.filled ?? f.authored)
            guard let t = get(d, f.keys) as? String, !hasPlaceholder(t), t.unicodeScalars.count > limit,
                  let s = cutAtWord(t, limit: limit) else { continue }
            set(&out, f.keys, s)
            cut.append(f.path)
        }
        return (out, cut)
    }

    /// `t` with whole trailing sentences dropped until it fits in `limit`: only sentences that hold no number, no
    /// placeholder and no list are dropped (a cut never shortens a list or a clause), and at least 60 % stays; else
    /// nil (the repair asks the model to shorten).
    static func cutAtWord(_ t: String, limit: Int) -> String? {
        let marked = t.replacingOccurrences(of: #"(?<=[.!?])\s+"#, with: "\u{1}", options: .regularExpression)
        var sentences = marked.split(separator: "\u{1}").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard sentences.count > 1 else { return nil }
        while sentences.count > 1, sentences.joined(separator: " ").unicodeScalars.count > limit {
            let last = sentences.removeLast()
            if last.rangeOfCharacter(from: .decimalDigits) != nil || last.contains("{") || last.contains(",") { return nil }
        }
        let s = sentences.joined(separator: " ")
        guard s.unicodeScalars.count <= limit, s.unicodeScalars.count * 10 >= t.unicodeScalars.count * 6 else { return nil }
        return s
    }
}
