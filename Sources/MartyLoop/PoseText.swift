// SPDX-License-Identifier: Apache-2.0
import Foundation
import MartyEngine

/// Pose-text agreement: what the force arrows shown in a posed step really do, from the engine, and whether the
/// step's words (or the follow-up answer) say the same. Marty applies the step's pose to a copy of the document, lets
/// the engine compile it, and reads the world anchors of the force arrows (not gravity) that the step shows.
/// Directions use the world frame; when the model has a mannequin, it faces -Y and its left is +X.
@MainActor public enum PoseText {
    public struct Push: Equatable {
        /// Sum of the arrows' unit directions along X (side) and Y; the sum of their horizontal sizes.
        public var side: Double, depth: Double, horizontal: Double
        /// Sum of sign(x position) * x direction: > 0 away from the middle (x = 0), < 0 toward it.
        public var outward: Double
        public var arrows: Int
        public var mannequin: Bool

        static let threshold = 0.2
        public var sideCancels: Bool { arrows > 0 && horizontal > Push.threshold && abs(side) < Push.threshold }
        public var noSidePush: Bool { arrows > 0 && abs(side) < Push.threshold }

        /// The facts in words, for the follow-up and answer prompts.
        public var summary: String {
            var s: [String] = []
            if noSidePush { s.append(horizontal > Push.threshold ? "the sideways parts of the thrusts cancel (no net sideways push)" : "no sideways push") }
            else { s.append("net sideways push toward " + (side > 0 ? (mannequin ? "the pilot's left (+X)" : "+X") : (mannequin ? "the pilot's right (-X)" : "-X"))) }
            if outward > Push.threshold { s.append("the side parts point away from the middle") }
            if outward < -Push.threshold { s.append("the side parts point toward the middle") }
            if mannequin, depth < -Push.threshold { s.append("a forward push") }
            if mannequin, depth > Push.threshold { s.append("a backward push") }
            return "In this step the shown thrust arrows give: " + s.joined(separator: "; ") + "."
        }
    }

    /// The document with `pose` applied to its parts: an instance's `with` merged, an inner part's `rot` set through
    /// the instance's `set`, a part's `rot` replaced.
    static func posed(_ doc: [String: Any], pose: [String: Any]) -> [String: Any] {
        var d = doc
        var parts = (d["parts"] as? [[String: Any]]) ?? []
        for (key, raw) in pose {
            guard let p = raw as? [String: Any] else { continue }
            let dot = key.firstIndex(of: ".")
            let id = dot.map { String(key[..<$0]) } ?? key
            guard let n = parts.firstIndex(where: { $0["id"] as? String == id }) else { continue }
            if let inner = dot.map({ String(key[key.index(after: $0)...]) }) {
                var set = parts[n]["set"] as? [String: Any] ?? [:]
                var e = set[inner] as? [String: Any] ?? [:]
                if let r = p["rot"] { e["rot"] = r }
                set[inner] = e; parts[n]["set"] = set
            } else {
                if let w = p["with"] as? [String: Any] { parts[n]["with"] = (parts[n]["with"] as? [String: Any] ?? [:]).merging(w) { _, b in b } }
                if let r = p["rot"] { parts[n]["rot"] = r }
            }
        }
        d["parts"] = parts
        return d
    }

    /// The push of the force arrows that `step` shows, at its pose, or nil when the engine cannot compile the posed
    /// copy or the step shows no force arrow.
    static func push(engine: MartyEngine, document doc: [String: Any], step: [String: Any], components: [Any]) -> Push? {
        let pose = (step["pose"] as? [String: Any]) ?? ((step["view"] as? [String: Any])?["pose"] as? [String: Any]) ?? [:]
        var copy = posed(doc, pose: pose)
        copy["steps"] = [["say": "Pose."]]
        guard let r = try? engine.check(document: copy, ref: nil, components: components, strict: false), (r["ok"] as? Bool) == true else { return nil }
        let arrows = ((doc["annotations"] as? [String: Any])?["arrows"] as? [[String: Any]]) ?? []
        let force = Set(arrows.filter { $0["meaning"] as? String == "force" && $0["cause"] as? String != "gravity" }.compactMap { $0["id"] as? String })
        let list = ((step["annotate"] ?? (step["view"] as? [String: Any])?["annotate"]) as? [String]).map(Set.init) ?? force
        var p = Push(side: 0, depth: 0, horizontal: 0, outward: 0, arrows: 0,
                     mannequin: (doc["parts"] as? [[String: Any]] ?? []).contains { $0["use"] as? String == "mannequin" })
        for a in r["annotations"] as? [[String: Any]] ?? [] {
            guard let id = a["id"] as? String, force.contains(id), list.contains(id),
                  let w = a["anchorsWorld"] as? [[Double]], w.count == 2, w[0].count == 3, w[1].count == 3 else { continue }
            let d = (0..<3).map { w[1][$0] - w[0][$0] }
            let len = sqrt(d.map { $0 * $0 }.reduce(0, +))
            guard len > 1e-9 else { continue }
            let ux = d[0] / len, uy = d[1] / len
            p.side += ux; p.depth += uy; p.horizontal += sqrt(ux * ux + uy * uy)
            if abs(w[0][0]) > 1e-6 { p.outward += (w[0][0] > 0 ? 1 : -1) * ux }
            p.arrows += 1
        }
        return p.arrows > 0 ? p : nil
    }

    /// The sentences of `text` whose direction words disagree with `push`.
    public static func disagreements(_ text: String, push p: Push) -> [String] {
        func has(_ s: String, _ re: String) -> Bool { s.range(of: re, options: [.regularExpression, .caseInsensitive]) != nil }
        return MartyLoop.sentences(text).filter { s in
            // "sideways" claimed while the side parts cancel (a hedge "cancel" in the same sentence is fine).
            if p.noSidePush, has(s, #"\b(sideways|to the side|slides?|sliding|side ?push|lateral)\b"#),
               !has(s, #"\b(cancel|cancels|balance|balances|no net|zero|equal and opposite)\b"#) { return true }
            if p.outward < -Push.threshold, has(s, #"\b(away from the (body'?s? )?(middle|centre|center)|outwards?)\b"#) { return true }
            if p.outward > Push.threshold, has(s, #"\b(towards? the (body'?s? )?(middle|centre|center)|inwards?)\b"#) { return true }
            if p.mannequin, p.depth > Push.threshold, has(s, #"\b(forwards?)\b"#), !has(s, #"\b(faces|facing)\b"#) { return true }
            if p.mannequin, p.depth < -Push.threshold, has(s, #"\b(backwards?)\b"#) { return true }
            if p.mannequin, !p.noSidePush {
                if p.side > 0, has(s, #"\b(to|toward|towards) the pilot'?s right\b"#) { return true }
                if p.side < 0, has(s, #"\b(to|toward|towards) the pilot'?s left\b"#) { return true }
            }
            return false
        }
    }
}
