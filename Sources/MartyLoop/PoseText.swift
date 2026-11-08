// SPDX-License-Identifier: Apache-2.0
import Foundation
import MartyEngine

/// Pose-text agreement: what the force arrows shown in a posed step really do, from the engine, and whether the
/// step's words (or the follow-up answer) say the same. The engine poses the step itself (`stepForceArrows`: its
/// own pose semantics, aliases and visibility) and gives the world anchors of the force arrows (not gravity) that
/// the step shows. With a mannequin, directions are read in its body frame at the pose (it faces -Y, its left is +X,
/// x = 0 is the body's middle); otherwise in the world frame.
@MainActor public enum PoseText {
    public struct Push: Equatable {
        /// Sums of the arrows' unit directions along the side (x) and depth (y) axes, and of |x|.
        public var side: Double, depth: Double, sideAbs: Double
        /// Sum of sign(x position) * x direction: > 0 away from the middle (x = 0), < 0 toward it.
        public var outward: Double
        public var arrows: Int
        public var mannequin: Bool

        static let threshold = 0.2
        public var noSidePush: Bool { abs(side) < Push.threshold }
        public var sideCancels: Bool { noSidePush && sideAbs > Push.threshold }

        /// The facts in words, for the follow-up and answer prompts.
        public var summary: String {
            var s: [String] = []
            if sideCancels { s.append("the sideways parts of the thrusts cancel (no net sideways push)") }
            else if noSidePush { s.append("no sideways push") }
            else { s.append("a net sideways push toward " + (side > 0 ? (mannequin ? "the pilot's left" : "+X") : (mannequin ? "the pilot's right" : "-X"))) }
            if outward > Push.threshold { s.append("the sideways parts point away from the middle") }
            if outward < -Push.threshold { s.append("the sideways parts point toward the middle") }
            if mannequin, depth < -Push.threshold { s.append("a forward push") }
            if mannequin, depth > Push.threshold { s.append("a backward push") }
            return "In this step the shown thrust arrows give: " + s.joined(separator: "; ") + "."
        }
    }

    /// An explainer as an assembly with one step per beat (its pose, show, hide and annotate), for posing a beat.
    static func assembly(explainer e: [String: Any]) -> [String: Any]? {
        guard var solid = e["solid"] as? [String: Any] else { return nil }
        solid["v"] = solid["v"] ?? 2
        solid["kind"] = "assembly"
        solid["title"] = "Explainer"
        solid["units"] = solid["units"] ?? "mm"
        solid["steps"] = (e["beats"] as? [[String: Any]] ?? []).map { b -> [String: Any] in
            var step: [String: Any] = ["say": "Beat."]
            for k in ["pose", "show", "hide", "annotate"] { if let v = (b["view"] as? [String: Any])?[k] { step[k] = v } }
            return step
        }
        return solid
    }

    /// The push of the force arrows that step `step` (0-based) of an assembly shows at its pose; nil when the engine
    /// cannot compile it or the step shows no force arrow.
    static func push(engine: MartyEngine, document doc: [String: Any], step: Int, components: [Any]) -> Push? {
        let man = (doc["parts"] as? [[String: Any]] ?? []).first { $0["use"] as? String == "mannequin" }?["id"] as? String
        guard let arrows = try? engine.stepForceArrows(document: doc, components: components, step: step, framePart: man.map { "\($0).body" }),
              !arrows.isEmpty else { return nil }
        var p = Push(side: 0, depth: 0, sideAbs: 0, outward: 0, arrows: 0, mannequin: man != nil)
        for a in arrows {
            let from = a.fromLocal ?? a.from, to = a.toLocal ?? a.to
            let d = (0..<3).map { to[$0] - from[$0] }
            let len = sqrt(d.map { $0 * $0 }.reduce(0, +))
            guard len > 1e-9 else { continue }
            let ux = d[0] / len, uy = d[1] / len
            p.side += ux; p.depth += uy; p.sideAbs += abs(ux)
            if abs(from[0]) > 1e-6 { p.outward += (from[0] > 0 ? 1 : -1) * ux }
            p.arrows += 1
        }
        return p.arrows > 0 ? p : nil
    }

    /// The steps (0-based) of `doc` whose pose, show, hide or annotate differ from the same step of `base` (or that
    /// are new) and that pose something.
    static func changedPosedSteps(_ doc: [String: Any], base: [String: Any]?) -> [Int] {
        let steps = doc["steps"] as? [[String: Any]] ?? [], old = base?["steps"] as? [[String: Any]] ?? []
        func view(_ s: [String: Any]) -> Data { MartyJSON.data(["pose": s["pose"] ?? NSNull(), "show": s["show"] ?? NSNull(), "hide": s["hide"] ?? NSNull()]) }
        return steps.indices.filter { n in
            steps[n]["pose"] != nil && (n >= old.count || view(old[n]) != view(steps[n]) || MartyJSON.data(old[n]["say"] ?? "") != MartyJSON.data(steps[n]["say"] ?? ""))
        }
    }

    /// The direction check of a changed document: for each changed posed step, its push and the sentences of its
    /// words (`says[n]`) that disagree. Returns the last push and the disagreements (with the push summary first).
    static func check(engine: MartyEngine, document doc: [String: Any], base: [String: Any]?, says: [String], components: [Any])
        -> (push: Push?, wrong: [String]) {
        var last: Push? = nil
        for n in changedPosedSteps(doc, base: base) {
            guard let p = push(engine: engine, document: doc, step: n, components: components) else { continue }
            last = p
            let wrong = disagreements(n < says.count ? says[n] : "", push: p)
            if !wrong.isEmpty { return (p, [p.summary] + wrong) }
        }
        return (last, [])
    }

    /// The clauses of a sentence (split at commas, semicolons, colons and "while", "but", "and", "so").
    static func clauses(_ s: String) -> [String] {
        s.replacingOccurrences(of: #"(?i)[,;:]|\b(while|but|and|so|whereas)\b"#, with: "\u{1}", options: .regularExpression)
            .split(separator: "\u{1}").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The sentences of `text` with a clause whose thrust-direction words disagree with `push`. A clause counts only
    /// when it speaks of thrust or push (so "the pilot slides the arm out" or "leans forward" are not claims), and a
    /// negated or cancelling clause ("no sideways push", "the side parts cancel") is no claim of a side push.
    public static func disagreements(_ text: String, push p: Push) -> [String] {
        func has(_ s: String, _ re: String) -> Bool { s.range(of: re, options: [.regularExpression, .caseInsensitive]) != nil }
        let thrust = #"\b(thrusts?|push(es|ing)?|forces?|jets?)\b"#
        let negated = #"\b(no|not|never|cancels?|cancelled|cancel out|zero|without|none|nothing)\b"#
        return MartyLoop.sentences(text).filter { sentence in
            // A clause speaks of thrust when it, or the clause just before it, names thrust ("the engines push
            // partly sideways, away from the middle").
            let cs = clauses(sentence)
            return cs.indices.contains { i in
                let c = cs[i]
                guard has(c, thrust) || (i > 0 && has(cs[i - 1], thrust)) else { return false }
                let neg = has(c, negated)
                if p.noSidePush, !neg, has(c, #"\b(sideways|to the side|slides?|sliding|side ?push(es)?|lateral(ly)?)\b"#) { return true }
                if !neg, p.outward < -Push.threshold, has(c, #"\b(away from the (body'?s? )?(middle|centre|center)|outwards?)\b"#) { return true }
                if !neg, p.outward > Push.threshold, has(c, #"\b(towards? the (body'?s? )?(middle|centre|center)|inwards?)\b"#) { return true }
                if !neg, p.mannequin, p.depth > Push.threshold, has(c, #"\bforwards?\b"#) { return true }
                if !neg, p.mannequin, p.depth < -Push.threshold, has(c, #"\bbackwards?\b"#) { return true }
                if !neg, p.mannequin, !p.noSidePush {
                    if p.side > 0, has(c, #"\b(to|toward|towards) the pilot'?s right\b"#) { return true }
                    if p.side < 0, has(c, #"\b(to|toward|towards) the pilot'?s left\b"#) { return true }
                }
                return false
            }
        }
    }
}
