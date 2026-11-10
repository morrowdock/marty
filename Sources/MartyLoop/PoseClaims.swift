// SPDX-License-Identifier: Apache-2.0
import Foundation

/// What an answer sentence may say from the posed views alone: a pose angle ("the left shoulder is raised 60 degrees")
/// or a comparison of the two sides ("the left arm is raised more than the right"). Each is checked against the posed
/// value of the side and joint it names, in the view it names (all of them), or in one posed view when it names none.
/// Anything else (another joint, the other direction, a value of another view) is no pose fact and stays checked.
@MainActor enum PoseClaims {
    /// The posed values per view: the view number of the posed line ("step 2 poses …" is 2) → the lower-case last name
    /// of each key ("leftshoulder") → its value (a number; for an axis-angle rot, its angle).
    static func facts(_ posed: [String]) -> [Int: [String: Double]] {
        var out: [Int: [String: Double]] = [:]
        for line in posed {
            guard let m = line.range(of: #"^(?:beat|step) (\d+) poses "#, options: .regularExpression),
                  let n = Int(line[m].split(separator: " ")[1]) else { continue }
            var values: [String: Double] = [:]
            func walk(_ v: Any) {
                guard let o = v as? [String: Any] else { return }
                for (k, x) in o {
                    let name = String(k.split(separator: ".").last ?? Substring(k)).lowercased()
                    if let num = x as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() { values[name] = num.doubleValue }
                    else if let a = x as? [Any], a.count == 4, let angle = a[3] as? NSNumber { values[name] = angle.doubleValue }
                    walk(x)
                }
            }
            if let p = MartyLoop.poseOfView(line) { walk(p) }
            out[n, default: [:]].merge(values) { _, b in b }
        }
        return out
    }

    /// A comparison of two posed limbs; its target is the other limb and ends the clause ("than the other", "than the
    /// right arm"; not "than the safety limit", "than the other model allows").
    static let comparison = #"(?i)\b(?:(raised|lowered|tilted|bent|angled)\s+(?:much\s+|far\s+)?(more|less|further|higher|lower)|(higher|lower|further))\s+than\s+(?:the\s+|its\s+|his\s+|her\s+)?(other|left|right)(?:\s+(?:one|arm|shoulder|elbow|forearm))?(?:\s+(?:does|is|was))?(?=\s*(?:$|[.,;:!?)]|and\b|but\b|while\b|so\b|as\b|in\b|at\b|on\b))"#

    /// Whether a sentence is about the pose alone: a limb or angle word, no performance, unit or share word, no
    /// comparison but a pose comparison, and no negation ("the left arm is not raised more than the right" is checked
    /// as it is).
    static func isPoseSentence(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        guard lower.range(of: #"\b(not|never|no|neither|nor|cannot|without)\b|n't\b|n\x{2019}t\b"#, options: .regularExpression) == nil else { return false }
        guard lower.range(of: #"\b(arm|arms|shoulder|shoulders|elbow|elbows|forearm|forearms|limb|limbs|degrees?|angle|angled|tilt\w*|rotat\w*|raised|lowered|bent)\b|\x{00B0}"#, options: .regularExpression) != nil,
              lower.range(of: #"\b(fuel|power|speed|weight|weighs?|mass|energy|force|load|lift|thrust|support|work|times|kg|kgf|lbf|newtons?|percent|bhp|hp|kw|litres?|liters?|mph|km|seconds?|minutes?|engines?|jets?|turbines?|pounds?|watts?)\b|%"#, options: .regularExpression) == nil
        else { return false }
        let rest = sentence.replacingOccurrences(of: comparison, with: " ", options: .regularExpression)
        let restWords = Set(rest.lowercased().split { !$0.isLetter }.map(String.init))
        return restWords.isDisjoint(with: QuoteCheck.shareWords) && rest.range(of: MartyLoop.comparativeWords, options: .regularExpression) == nil
    }

    /// The view numbers a sentence names ("step 2", "beats 2 and 3", "steps 2-4").
    static func namedViews(_ sentence: String) -> [Int] {
        guard let re = try? NSRegularExpression(pattern: #"(?i)\b(?:beats?|steps?)\s+(\d+(?:\s*(?:,\s*(?:and|or)?|and|or|to|through|thru|-|\x{2013})\s*\d+)*)\b"#) else { return [] }
        let ns = sentence as NSString
        var out: [Int] = []
        for m in re.matches(in: sentence, range: NSRange(location: 0, length: ns.length)) {
            let list = ns.substring(with: m.range(at: 1))
            let nums = list.split { !$0.isNumber }.compactMap { Int($0) }
            if nums.count == 2, list.range(of: #"to|through|thru|-|\x{2013}"#, options: .regularExpression) != nil, nums[0] <= nums[1], nums[1] - nums[0] < 50 {
                out += Array(nums[0]...nums[1])
            } else { out += nums }
        }
        return out
    }

    /// Whether every pose claim of the sentence (its angles and its comparison; at least one) holds in each named view,
    /// or, when it names none, in one posed view. `sentence` is the text with view numbers taken out.
    static func holds(_ sentence: String, views named: [Int], facts: [Int: [String: Double]]) -> Bool {
        if named.isEmpty { return facts.values.contains { holds(sentence, in: $0) } }
        return named.allSatisfy { v in facts[v].map { holds(sentence, in: $0) } ?? false }
    }

    static let sideRE = #"\b(left|right)\b"#
    static let jointRE = #"\b(shoulder|elbow|arm|forearm)s?\b"#
    static let separators = #"(?s)^.*(?:[,;:]|\band\b|\bbut\b|\bwhile\b|\bwhereas\b|\bso\b|\bor\b)"#

    static func last(_ re: String, _ t: String) -> String? {
        guard let x = try? NSRegularExpression(pattern: re) else { return nil }
        let tn = t as NSString
        return x.matches(in: t, range: NSRange(location: 0, length: tn.length)).last.map { tn.substring(with: $0.range(at: 1)) }
    }

    static func jointKey(_ word: String) -> String { ["arm": "shoulder", "forearm": "elbow"][word, default: word] }

    static func holds(_ sentence: String, in values: [String: Double]) -> Bool {
        let lower = sentence.lowercased()
        let ns = lower as NSString
        var claims = 0
        // Each comparison: the subject's side and joint (before it, in its clause) against the target's side.
        guard let re = try? NSRegularExpression(pattern: comparison) else { return false }
        for m in re.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
            claims += 1
            let subject = ns.substring(to: m.range.location).replacingOccurrences(of: separators, with: "", options: .regularExpression)
            let phrase = ns.substring(with: m.range)
            func group(_ k: Int) -> String? { m.range(at: k).location == NSNotFound ? nil : ns.substring(with: m.range(at: k)) }
            guard let jointWord = last(jointRE, subject) ?? last(jointRE, phrase), let target = group(4) else { return false }
            let joint = jointKey(jointWord)
            guard let l = values["left" + joint], let r = values["right" + joint] else { return false }
            let side = last(sideRE, subject)
            if let side {
                let other = side == "left" ? "right" : "left"
                guard target == "other" || target == other else { return false }
                let word = group(2) ?? group(3) ?? ""
                var sign: Double = ["more", "higher", "further"].contains(word) ? 1 : -1
                if group(1) == "lowered" { sign = -sign }
                let (a, b) = side == "left" ? (l, r) : (r, l)
                guard (a - b) * sign > 0 else { return false }
            } else {
                // "One arm is raised more than the other": the two sides differ.
                guard target == "other", l != r else { return false }
            }
        }
        // Each number: an angle (a degree word or sign after it, or a bare number set by a pose verb) of the side and
        // joint named last in its clause, else earlier in the sentence, equal to that posed value.
        let poseVerb = lower.range(of: #"\b(rais\w*|lower\w*|tilt\w*|bend\w*|bent|angl\w*|rotat\w*|turn\w*|swing\w*|swung|pos\w*|set|sets)\b"#, options: .regularExpression) != nil
        // (A signed number is one: "-60" is no "60"; the minus sign U+2212 too.)
        guard let numRE = try? NSRegularExpression(pattern: #"(?<![\w.])[-\x{2212}]?\d+(?:\.\d+)?"#) else { return false }
        var previousEnd = 0
        for m in numRE.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
            claims += 1
            let after = ns.substring(from: m.range.location + m.range.length)
            let before = ns.substring(to: m.range.location)
            // A number whose own subject (the text since the number before it) names both sides, or both or each, is
            // shared ("the left and right shoulders are raised 60 degrees"): no single posed value, so not exempt.
            let own = ns.substring(with: NSRange(location: previousEnd, length: m.range.location - previousEnd))
            previousEnd = m.range.location + m.range.length
            if (own.range(of: #"\bleft\b"#, options: .regularExpression) != nil && own.range(of: #"\bright\b"#, options: .regularExpression) != nil)
                || own.range(of: #"\b(both|each|all)\b"#, options: .regularExpression) != nil { return false }
            let angle = after.range(of: #"^\s*(?:\x{00B0}|degrees?\b|deg\b)"#, options: .regularExpression) != nil
            let bare = poseVerb && before.range(of: #"\b(?:to|at|by)\s+$"#, options: .regularExpression) != nil
                && after.range(of: #"^\s*(?:$|[.,;:!?)]|and\b|or\b|while\b|so\b|but\b)"#, options: .regularExpression) != nil
            guard angle || bare else { return false }
            let clause = before.replacingOccurrences(of: separators, with: "", options: .regularExpression)
            guard clause.range(of: #"\b(arm|arms|shoulder|shoulders|elbow|elbows|forearm|forearms|limb|limbs|left|right)\b"#, options: .regularExpression) != nil,
                  let side = last(sideRE, clause) ?? last(sideRE, before),
                  let joint = last(jointRE, clause) ?? last(jointRE, before),
                  let value = values[side + jointKey(joint)],
                  let n = Double(ns.substring(with: m.range).replacingOccurrences(of: "\u{2212}", with: "-")), value == n
            else { return false }
        }
        // A clause after the last number that names a limb or side again, or reuses the value ("and the right
        // shoulder is too", "as well", "the same"), gives it to another limb unchecked: not exempt.
        // (A comparison clause there is checked above.)
        if let lastEnd = numRE.matches(in: lower, range: NSRange(location: 0, length: ns.length)).last.map({ $0.range.location + $0.range.length }) {
            let tail = ns.substring(from: lastEnd).replacingOccurrences(of: #"^\s*(?:\x{00B0}|degrees?\b|deg\b)"#, with: "", options: .regularExpression)
            let clauses = tail.replacingOccurrences(of: #"[,;:]|\band\b|\bbut\b|\bso\b|\bwhile\b|\bwhereas\b"#, with: "\u{1}", options: .regularExpression)
                .components(separatedBy: "\u{1}").filter { $0.range(of: comparison, options: .regularExpression) == nil }
            if clauses.contains(where: { $0.range(of: #"\b(left|right|other|arm|arms|shoulder|shoulders|elbow|elbows|forearm|forearms|limb|limbs|too|also|likewise|same|both|each)\b|\bas well\b"#, options: .regularExpression) != nil }) {
                return false
            }
        }
        return claims > 0
    }
}
