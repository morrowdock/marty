// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The research phase's FACT TABLE: what the lesson may state beyond the engine's own solved facts. The model fills it
/// with web search; Marty checks its form and its labels mechanically (it cannot read the sources itself here):
/// VERIFIED needs two sources from different sites, a CLAIM needs one source, a row from a blocked site loses that
/// source, and a row that keeps no source is PLAUSIBLE (no value) or UNKNOWN. Every change is listed in `downgrades`.
public struct FactTable {
    public enum Label: String, CaseIterable { case verified = "VERIFIED", claim = "CLAIM", plausible = "PLAUSIBLE", unknown = "UNKNOWN" }

    public struct Source {
        public var url: String
        public var publisher: String
        public var date: String
        public var quote: String
        /// The site, for the independence rule: the host without "www.". Two sources are the same site when one host
        /// equals the other or is a subdomain of it.
        public var host: String
    }

    public struct Row {
        public var id: String
        public var claim: String
        public var value: String
        public var unit: String
        public var label: Label
        public var appliesTo: String
        public var sources: [Source]
    }

    public var needed: Bool
    public var rows: [Row]
    public var downgrades: [String]

    public static let maxRows = 20
    public static let maxSources = 3
    public static let empty = FactTable(needed: false, rows: [], downgrades: [])

    /// Parses and checks a research reply: `{"needed": bool, "rows": [...]}`. Nil when the reply has no such object.
    public static func parse(_ text: String, blocked: [String] = ResearchLimits.defaultBlocked) -> FactTable? {
        guard let o = ReplyJSON.object(text) else { return nil }
        let needed = o["needed"] as? Bool ?? true
        var rows: [Row] = []
        var downgrades: [String] = []
        var ids = Set<String>()
        for (n, any) in (o["rows"] as? [Any] ?? []).enumerated() {
            guard rows.count < maxRows else { downgrades.append("rows over \(maxRows) dropped"); break }
            guard let r = any as? [String: Any] else { continue }
            var id = clip(r["id"], 8)
            if id.range(of: #"^F[0-9]{1,2}$"#, options: .regularExpression) == nil || ids.contains(id) { id = "F\(n + 1)" }
            while ids.contains(id) { id += "b" }
            ids.insert(id)
            let claim = clip(r["claim"], 200)
            guard !claim.isEmpty else { continue }
            var label = Label(rawValue: clip(r["label"], 12).uppercased()) ?? .unknown
            var sources: [Source] = []
            for s in (r["sources"] as? [[String: Any]] ?? []).prefix(maxSources) {
                let url = clip(s["url"], 300)
                guard let u = URL(string: url), let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http",
                      var host = u.host?.lowercased() else { continue }
                if host.hasPrefix("www.") { host.removeFirst(4) }
                if blocked.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    downgrades.append("\(id): source on a blocked site dropped (\(host))"); continue
                }
                sources.append(Source(url: url, publisher: clip(s["publisher"], 80), date: clip(s["date"], 20),
                                      quote: clip(s["quote"], 200), host: host))
            }
            let sites = distinctSites(sources)
            let before = label
            switch label {
            case .verified where sites < 2: label = sources.isEmpty ? .plausible : .claim
            case .claim where sources.isEmpty: label = .plausible
            default: break
            }
            if label != before { downgrades.append("\(id): \(before.rawValue) to \(label.rawValue) (\(sites) source site\(sites == 1 ? "" : "s"))") }
            var value = clip(r["value"], 60)
            if label == .unknown { value = "" }
            rows.append(Row(id: id, claim: claim, value: value, unit: clip(r["unit"], 20), label: label,
                            appliesTo: clip(r["appliesTo"], 80), sources: sources))
        }
        return FactTable(needed: needed, rows: rows, downgrades: downgrades)
    }

    /// Sites that count as independent: hosts compared after "www.", a subdomain counting as its parent's site.
    static func distinctSites(_ sources: [Source]) -> Int {
        var sites: [String] = []
        for s in sources where !sites.contains(where: { s.host == $0 || s.host.hasSuffix("." + $0) || $0.hasSuffix("." + s.host) }) {
            sites.append(s.host)
        }
        return sites.count
    }

    static func clip(_ v: Any?, _ n: Int) -> String {
        let s = (v as? String) ?? (v as? NSNumber).map { "\($0)" } ?? ""
        let t = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(t.prefix(n))).trimmingCharacters(in: .whitespaces)
    }

    /// One line per row for the plan, author, follow-up and answer prompts.
    public var lines: [String] {
        rows.map { r in
            var s = "\(r.id) [\(r.label.rawValue)] \(r.claim)"
            if !r.value.isEmpty { s += ": \(r.value)" + (r.unit.isEmpty ? "" : " \(r.unit)") }
            if !r.appliesTo.isEmpty { s += " (applies to: \(r.appliesTo))" }
            let src = r.sources.map { [$0.publisher.isEmpty ? $0.host : $0.publisher, $0.date].filter { !$0.isEmpty }.joined(separator: " ") }
            if !src.isEmpty { s += " — " + src.joined(separator: "; ") }
            return s
        }
    }

    /// The prompt block: the rows, or a line saying there is no table.
    public var promptBlock: String {
        rows.isEmpty
            ? "Fact table: none (no research). State no figure, date, product version or share that the engine did not solve."
            : "Fact table (from research; state only these facts, with their label and row id):\n" + lines.joined(separator: "\n")
    }

    /// For the receipt.
    public var json: [String: Any] {
        ["needed": needed, "downgrades": downgrades,
         "rows": rows.map { r in
             ["id": r.id, "claim": r.claim, "value": r.value, "unit": r.unit, "label": r.label.rawValue, "appliesTo": r.appliesTo,
              "sources": r.sources.map { ["url": $0.url, "publisher": $0.publisher, "date": $0.date, "quote": $0.quote] }] as [String: Any]
         }]
    }
}
