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
            for k in ["pose", "show", "hide", "annotate", "spin", "explode"] { if let v = (b["view"] as? [String: Any])?[k] { step[k] = v } }
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

    /// The steps (0-based) to check: posed in either document (so a removed pose counts) and different from the same
    /// step of `base` in pose, show, hide, annotate, spin, explode or words (`says` against `baseSays`, the original
    /// captions), or new.
    static func changedSteps(_ doc: [String: Any], base: [String: Any]?, says: [String], baseSays: [String]) -> [Int] {
        let steps = doc["steps"] as? [[String: Any]] ?? [], old = base?["steps"] as? [[String: Any]] ?? []
        func view(_ s: [String: Any]) -> Data {
            MartyJSON.data(["pose": s["pose"] ?? NSNull(), "show": s["show"] ?? NSNull(), "hide": s["hide"] ?? NSNull(),
                            "annotate": s["annotate"] ?? NSNull(), "spin": s["spin"] ?? NSNull(), "explode": s["explode"] ?? NSNull()])
        }
        return steps.indices.filter { n in
            let posed = steps[n]["pose"] != nil || (n < old.count && old[n]["pose"] != nil)
            guard posed else { return false }
            if n >= old.count { return true }
            return view(old[n]) != view(steps[n]) || (n < says.count ? says[n] : "") != (n < baseSays.count ? baseSays[n] : "")
        }
    }

    /// The direction check of a changed document: for each changed posed step, its push and the sentences of its
    /// words (`says[n]`) that disagree. Returns the last push and the disagreements (with the push summary first).
    static func check(engine: MartyEngine, document doc: [String: Any], base: [String: Any]?, says: [String], baseSays: [String],
                      components: [Any]) -> (push: Push?, wrong: [String]) {
        var last: Push? = nil
        for n in changedSteps(doc, base: base, says: says, baseSays: baseSays) {
            guard let p = push(engine: engine, document: doc, step: n, components: components) else { continue }
            last = p
            let wrong = disagreements(n < says.count ? says[n] : "", push: p)
            if !wrong.isEmpty { return (p, [p.summary] + wrong) }
        }
        return (last, [])
    }

    static let body = #"(the )?(suit|pilot|body|wearer|flyer)|it|him|her|them"#
    static let thrust = #"\b(thrusts?|push(es|ing)?|forces?|jets?|exhausts?|engines?)\b"#

    /// The sentences of `text` that make a claim the push contradicts. Claims are matched over the whole sentence:
    /// a net side motion of the body ("pushes the suit sideways", "the suit slides sideways", "the side push moves
    /// it"), exempt only when the sentence says the side parts cancel; thrust pointing away from or toward the middle
    /// (or outward, inward); thrust or the body pushed forward or backward; "to the pilot's left/right".
    public static func disagreements(_ text: String, push p: Push) -> [String] {
        func has(_ s: String, _ re: String) -> Bool { s.range(of: re, options: [.regularExpression, .caseInsensitive]) != nil }
        let b = body
        let sideMotion = #"\b(push(es|ed|ing)?|mov(es|ed|ing)|drives?|carr(y|ies)|shoves?|shifts?|nudges?)\s+("# + b + #")\s+(sideways|to the side|laterally)\b"#
            + #"|\b("# + b + #")\s+(slides?|drifts?|moves?|shifts?|goes|travels?)\s+(sideways|to the side|laterally)\b"#
            + #"|\b(net sideways|sideways (push|force|motion|movement)|side ?(push|force)|lateral (push|force))\b"#
            + #"|\b(sideways|side) (part|component)s? (push(es)?|moves?|drives?|shoves?)\b"#
        let cancels = #"\b(cancel\w*|no net|no sideways|zero net|balance out|net side(ways)? (push|force) is (zero|nil))\b"#
        let toward = #"\b(towards?|in toward) the (body'?s? )?(middle|centre|center|midline)\b|\binwards?\b"#
        let away = #"\baway from the (body'?s? )?(middle|centre|center|midline)\b|\boutwards?\b"#
        return MartyLoop.sentences(text).filter { s in
            if p.noSidePush, has(s, sideMotion), !has(s, cancels) { return true }
            if has(s, thrust) {
                if p.outward < -Push.threshold, has(s, away) { return true }
                if p.outward > Push.threshold, has(s, toward) { return true }
            }
            if p.mannequin {
                let fwd = #"\b(push(es|ed|ing)?|mov(es|ed|ing)|drives?)\s+("# + b + #")\s+forwards?\b|\b(thrust|push|force)\b[^.]*\bforwards?\b"#
                let bwd = #"\b(push(es|ed|ing)?|mov(es|ed|ing)|drives?)\s+("# + b + #")\s+backwards?\b|\b(thrust|push|force)\b[^.]*\bbackwards?\b"#
                if p.depth > Push.threshold, has(s, fwd) { return true }
                if p.depth < -Push.threshold, has(s, bwd) { return true }
                if !p.noSidePush {
                    if p.side > 0, has(s, #"\b(to|toward|towards) the pilot'?s right\b"#) { return true }
                    if p.side < 0, has(s, #"\b(to|toward|towards) the pilot'?s left\b"#) { return true }
                }
            }
            return false
        }
    }
}
