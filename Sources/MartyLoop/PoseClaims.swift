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

    /// The posed joint a limb word names: an arm is its shoulder ("raised"), but a bent arm is its elbow.
    static func jointKey(_ word: String, verb: String? = nil) -> String {
        if verb == "bent", word == "arm" || word == "forearm" { return "elbow" }
        return ["arm": "shoulder", "forearm": "elbow"][word, default: word]
    }

    /// The clause grammar of a pose sentence. Each clause (split at commas and at "and", "so", "while") is exactly one of:
    /// an angle, "[the] left|right [shoulder|arm|elbow|forearm] [is] [raised|bent|set|...] [to|at|by] N [degrees]" (with
    /// "to/at/by" or a degree word; the joint may come from the clause before, "and the
    /// right to 15"); or a comparison, "[the] left|right|one <joint> is raised|lowered|bent [much|far] more|less|higher|
    /// lower|further than [the] other|left|right [one|<joint>]". A view word and a pose verb may lead ("Step raises
    /// the left shoulder to 60"). Anything more (a reference frame, "above horizontal"; another limb, "both elbows
    /// are bent"; a negation) is no pose clause, so the sentence is not exempt.
    static let anglePattern = #"^(?:the\s+)?(left|right)(?:\s+(shoulder|arm|elbow|forearm))?(?:\s+(?:is|sits))?(?:\s+(raised|bent|set|posed|lifted|angled))?(?:\s+(to|at|by))?\s+([-\x{2212}]?\d+(?:\.\d+)?)(?:\s*(degrees?|deg|\x{00B0}))?$"#
    static let comparisonPattern = #"^(?:the\s+)?(left|right|one)\s+(arm|shoulder|elbow|forearm)\s+is\s+(raised|lowered|bent)\s+(?:much\s+|far\s+)?(more|less|higher|lower|further)\s+than\s+(?:the\s+)?(other|left|right)(?:\s+(?:one|arm|shoulder|elbow|forearm))?$"#

    static func holds(_ sentence: String, in values: [String: Double]) -> Bool {
        // (A leading view phrase, "In step 1, …", is no clause: the views it names are checked by the caller.)
        let lower = sentence.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
            .replacingOccurrences(of: #"^(?:(?:in|at)\s+)?(?:the\s+)?(?:beats?|steps?)(?:\s+(?:and|to|through)\s*)?\s*,\s*"#, with: "", options: .regularExpression)
        let clauses = lower.replacingOccurrences(of: #"\s*[,;]\s*(?:(?:and|so|while)\s+)?|\s+(?:and|so|while)\s+"#, with: "\u{1}", options: .regularExpression)
            .components(separatedBy: "\u{1}").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !clauses.isEmpty, let angleRE = try? NSRegularExpression(pattern: anglePattern),
              let compRE = try? NSRegularExpression(pattern: comparisonPattern) else { return false }
        var joint: String? = nil
        // The leading pose verb ("Step 1 bends the left arm to 60") holds for the clauses after it too.
        var leadVerb: String? = nil
        for raw in clauses {
            // A leading view word ("in step", "beat") and pose verb ("raises", "shows").
            var c = raw.replacingOccurrences(of: #"^(?:(?:in|at)\s+)?(?:the\s+)?(?:beats?|steps?)\b\s*"#, with: "", options: .regularExpression)
            if let r = c.range(of: #"^(?:shows\s+)?(raises|bends|sets|poses|lifts)\s+"#, options: .regularExpression) {
                leadVerb = c[r].contains("bends") ? "bent" : "raised"
                c.removeSubrange(r)
            }
            let cn = c as NSString
            let all = NSRange(location: 0, length: cn.length)
            func g(_ m: NSTextCheckingResult, _ k: Int) -> String? { m.range(at: k).location == NSNotFound ? nil : cn.substring(with: m.range(at: k)) }
            if let m = compRE.firstMatch(in: c, range: all) {
                guard let subject = g(m, 1), let j = g(m, 2), let verb = g(m, 3), let word = g(m, 4), let target = g(m, 5) else { return false }
                let key = jointKey(j, verb: verb)
                joint = key
                leadVerb = verb == "bent" ? "bent" : "raised"
                guard let l = values["left" + key], let r = values["right" + key] else { return false }
                if subject == "one" {
                    guard target == "other", l != r else { return false }
                } else {
                    let other = subject == "left" ? "right" : "left"
                    guard target == "other" || target == other else { return false }
                    var sign: Double = ["more", "higher", "further"].contains(word) ? 1 : -1
                    if verb == "lowered" { sign = -sign }
                    let (a, b) = subject == "left" ? (l, r) : (r, l)
                    guard (a - b) * sign > 0 else { return false }
                }
            } else if let m = angleRE.firstMatch(in: c, range: all) {
                guard let side = g(m, 1), let number = g(m, 5) else { return false }
                // ("to/at/by" or a degree word: "and the right shoulder 15 degrees" is the clause before's verb.)
                guard g(m, 4) != nil || g(m, 6) != nil else { return false }
                // (The clause's own verb, else the one before it: "bent to 60 and the right arm to 15" is bent too.)
                if let v = g(m, 3) { leadVerb = v == "bent" ? "bent" : "raised" }
                guard let key = g(m, 2).map({ jointKey($0, verb: leadVerb) }) ?? joint else { return false }
                joint = key
                guard let value = values[side + key], let n = Double(number.replacingOccurrences(of: "\u{2212}", with: "-")), value == n else { return false }
            } else {
                return false
            }
        }
        return true
    }
}
