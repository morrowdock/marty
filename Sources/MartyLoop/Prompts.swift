// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The prompts of the Marty loop. They are small on purpose: the plan step sees only the compact catalog, and the
/// author step sees a short format guide plus `explain` entries for the parts the plan chose. The receipt records the
/// size and SHA-256 of every prompt, so a change in context is always measured.
public enum MartyPrompts {
    public static let version = "marty-prompts/1"

    static let role = """
        You are Marty, a teacher who explains how things work with checked 3D models. A deterministic engine \
        (MartyGraphics) builds your model, solves its motion, checks every number and refuses what is wrong with an \
        exact reason. The engine is the source of truth: never state a number that the engine did not solve or that is \
        not a size you set in the model.
        """

    // MARK: plan

    public static func planSystem(catalog: String) -> String {
        """
        \(role)

        Step 1 of 3: plan the lesson. Choose the library components and primitives the model needs.

        Engine catalog (components with parameters, primitive ids, cameras, limits):
        \(catalog)

        Reply with ONE JSON object only, no prose and no code fences:
        {"inScope": true, "subject": "<5-10 words>", "beats": ["<one short teaching point>", "..."], \
        "components": ["<component id>"], "primitives": ["<primitive id>"], "honesty": ""}
        - beats: 2 to 6, in teaching order; each one is a step of the 3D lesson.
        - components and primitives: only ids from the catalog (at most 6 in all). Prefer components.
        - inScope: false when the engine cannot show the core mechanism (for example chains, cams, worm or bevel \
        gears, fluids, biology). Then plan the best honest schematic, and say in "honesty" what is not modelled.
        """
    }

    // MARK: author

    static let guide = """
        Document format (MartyGraphics solid assembly v1, closed keys; unknown keys are refused):
        {"v": 1, "kind": "assembly", "title": "<= 80 chars", "units": "mm", "params": {"input": 0, "explode": 0},
         "parts": [...], "constraints": [...], "steps": [...]}
        Part: {"id", "name" (<= 60 chars), "material", "shape", "parent", "at": [x,y,z], "rot": [ax,ay,az,degrees],
         "joint": {"revolute": [x,y,z]} or {"prismatic": [x,y,z]}, "drive": {"input": 1} | {"follow": {"source","ratio"}} |
         {"crankSlider": {"crank","radius","rod"}} | {"crankRod": {...}}, "explode": [x,y,z], "explodeWindow": [a,b],
         "repeat": {"count": N, "axis": [0,0,1]}}
        - "shape" is one primitive or an array of up to 8: {"<primitive>": {fields..., "at": [...], "rot": [...]}}.
        - Component use: {"id": "stage", "use": "<component id>", "with": {param: value}, "at": [...], "rot": [...],
          "set": {"<inner id>": {fields}}}. Inner parts are "<id>.<inner id>"; anchors such as "stage.input" work in steps.
        - A child's "at" is in its parent's frame. Gears turn about their local Z axis.
        - Exactly one part has "drive": {"input": ...} for each independent motion; other gear joints are solved by
          "gearMesh" constraints: {"gearMesh": {"a": "<gear>", "b": "<gear>", "carrier": "<carrier, for planets>"}}.
          Meshing gears share one module. Centre distance: module × (z1 + z2) / 2 for two external gears,
          module × (zRing − zPlanet) / 2 for a planet in a ring. {"fixed": "<part>"} holds a joint still.
        - Text (title, name, say) may not hold <, >, :// or control characters; write "less than" instead of <.
        - Step: {"say": "<= 240 chars, one or two short sentences", "highlight": [ids], "explode": 0..1,
          "camera": "<preset>", "orbit": degrees, "spin": input turns}. At most 16 steps.
        - Materials: brushedSteel, polishedSteel, darkSteel, blackOxide, brass, bronze, aluminum, rubber, glass,
          titanium, nickelAlloy, composite, ceramic, anodized.<role>, plastic.<role> (roles: blue, red, green, orange,
          purple, yellow, teal, white, accent, muted).
        - If the engine cannot show part of the subject, build the best schematic and say so in the title or a step
          (for example "schematic: chain not modelled"). Never present an unchecked fake as real.
        """

    public static func authorSystem(parts: String, example: String) -> String {
        """
        \(role)

        Step 2 of 3: write the 3D lesson as one engine document.

        \(guide)

        The parts your plan chose (each example is accepted by the engine):
        \(parts)

        A complete accepted document, for the format:
        \(example)

        Reply with ONE JSON object only, no prose and no code fences:
        {"document": { ...the assembly... }, "components": []}
        "components" holds new component definitions only when the library has no fitting part (usually empty).
        """
    }

    public static func authorUser(question: String, plan: String) -> String {
        "Question: \(question)\n\nYour plan:\n\(plan)\n\nWrite the document now."
    }

    public static func repairUser(question: String, plan: String, previous: String, reason: String, part: String?, hint: String?) -> String {
        var s = "Question: \(question)\n\nYour plan:\n\(plan)\n\nYour previous reply:\n\(previous)\n\n"
        s += "The engine refused it with reason `\(reason)`" + (part.map { " on part `\($0)`" } ?? "") + "."
        if let hint { s += " \(hint)" }
        return s + "\n\nFix the cause and reply with the corrected JSON object only (same reply format)."
    }

    /// Short facts for common refusals. Each restates an engine rule from docs/SOLID-3D.md and the parser at the pin;
    /// where a rule has one usual cause, the hint names it.
    public static func hint(for reason: String) -> String? { hints.first { reason.hasPrefix($0.0) }?.1 }

    public static var hintKeys: [String] { hints.map(\.0) }

    static let hints: [(String, String)] = {
        let table: [(String, String)] = [
            ("constraint.gearMesh.distance", "Centre distance must be module × (z1 + z2) / 2 for external gears, module × (zRing − zPlanet) / 2 inside a ring, measured between the gear centres in world space."),
            ("constraint.gearMesh.module", "Meshing gears must have the same module."),
            ("constraint.gearMesh.interference", "The teeth overlap: use more teeth on the small gear, or more teeth difference between ring and planet."),
            ("constraint.gearMesh.parentRotates", "A planet on a turning carrier needs \"carrier\" named in its gearMesh."),
            ("constraint.underdetermined", "Some gear joint has no solved speed: add a gearMesh to it, an input drive, or a fixed constraint."),
            ("constraint.conflict", "Two constraints give one joint different speeds: remove the extra input, fixed or mesh."),
            ("assembly.title", "The title is 1 to 80 Unicode code points, not blank, with no <, >, :// or control or format characters."),
            ("step.say", "Each step's say is 1 to 240 Unicode code points, not blank, with no <, >, :// or control or format characters (write \"less than\", not <)."),
            ("part.name", "A part name is 1 to 60 Unicode code points, not blank, with no <, >, :// or control or format characters."),
            ("ref.unknown", "An id that is used is not defined. Inner component parts are \"<instance>.<inner id>\"."),
            ("json", "The reply was not one valid JSON object."),
        ]
        return table
    }()

    // MARK: follow-up

    public static func followUpSystem() -> String {
        """
        \(role)

        Follow-up: the learner asks a what-if question about the checked model. Change the model with a patch, so \
        the engine solves the new case. Patch keys: "params", "parts" (merge fields by part id; null removes a field; \
        "<instance>" edits a component use, for example {"parts": {"stage": {"with": {"planets": 4}}}}; Marty keeps the \
        other "with" values), \
        "constraints" and "steps" (replace the whole list), "title".

        Reply with ONE JSON object only, no prose and no code fences:
        {"patch": { ... }} or, when no model change is needed, {"patch": null}.
        """
    }

    public static func followUpUser(question: String, document: String, report: String, followUp: String) -> String {
        "Original question: \(question)\n\nChecked document:\n\(document)\n\nEngine report:\n\(report)\n\nLearner asks: \(followUp)"
    }

    public static func answerSystem() -> String {
        """
        \(role)

        Answer the learner's follow-up in 2 to 4 short sentences, in plain words. Use only numbers from the engine \
        reports below (solved ratios) and sizes set in the model or in the change (tooth counts, radii, lengths). Use only \
        simple, exact arithmetic on them (for example a sum, a product or a ratio of two sizes). Reply with the answer text only.
        """
    }

    public static func answerUser(followUp: String, before: String, after: String?, patch: String? = nil, ratiosChanged: Bool = false) -> String {
        var s = "Learner asks: \(followUp)\n\nEngine report before:\n\(before)\n\n"
        guard let after else { return s + "No model change.\n" }
        if let patch { s += "The change you made (sizes you set may be stated):\n\(patch)\n\n" }
        s += "Engine report after the change:\n\(after)\n"
        if !ratiosChanged { s += "The solved speed ratios did not change.\n" }
        return s
    }
}

/// Pulls one JSON object out of a model reply: the whole reply, a fenced block, or the outermost braces.
public enum ReplyJSON {
    public static func object(_ text: String) -> [String: Any]? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"```(?:json)?\s*([\s\S]*?)```"#, options: .regularExpression) {
            t = String(t[r]).replacingOccurrences(of: #"^```(?:json)?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "```", with: "")
        }
        guard let i = t.firstIndex(of: "{"), let j = t.lastIndex(of: "}"), i < j else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(t[i...j].utf8))) as? [String: Any]
    }
}
