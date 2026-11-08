// SPDX-License-Identifier: Apache-2.0
import Foundation
import MartyEngine

/// One MCP tool: its name, description and input schema, and the closed set of argument names it accepts.
struct Tool {
    let name: String
    let title: String
    let description: String
    let properties: [String: Any]
    let required: [String]
    let readOnly: Bool

    var definition: [String: Any] {
        ["name": name, "title": title, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
         "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]]
    }
}

enum Schema {
    /// `anyOf` rather than a type array, which some schema converters (for example to the OpenAPI subset) reject.
    static let objectOrString: [[String: Any]] = [["type": "object"], ["type": "string"]]
    static let document: [String: Any] = [
        "anyOf": objectOrString,
        "description": "A solid assembly document (MartyGraphics v1 or v2) or an explainer document (kind explainer), as a JSON object or a string that holds it. At most 64 KiB.",
    ]
    static let ref: [String: Any] = [
        "type": "string",
        "description": "`ref` from an earlier result (sha256:...), in place of `document`. The server keeps the last 32 documents.",
    ]
    static let strict: [String: Any] = [
        "type": "boolean",
        "description": "The engine's strict profile for model authors (default true): also refuse a jointed part that nothing moves (joint.idle.<id>) and a turn axis that misses its own part (frame.axis.off.<id>). false gives the plain profile, where these are only warnings.",
    ]
    static let components: [String: Any] = [
        "type": "array", "maxItems": MartyLimits.componentsPerRequest,
        "items": ["anyOf": objectOrString],
        "description": "Extra component definitions (each at most 16 KiB), registered in order after the built-in library.",
    ]
}

enum Tools {
    static let all: [Tool] = [
        Tool(name: "catalog", title: "Engine catalog",
             description: "List the components (id, about, parameters with default and range, inner parts, anchors), the primitive shapes, joints, drives and constraints, the camera presets and the format limits. Call this first.",
             properties: ["compact": ["type": "boolean", "description": "Ids only for primitives (default true)."], "components": Schema.components],
             required: [], readOnly: true),
        Tool(name: "explain", title: "Explain one part",
             description: "Explain one component or primitive by id: what it is, its keys or parameters, and an example the engine accepts.",
             properties: ["id": ["type": "string", "maxLength": MartyLimits.idLength], "components": Schema.components],
             required: ["id"], readOnly: true),
        Tool(name: "check", title: "Check a document",
             description: "Check a solid assembly or an explainer document (2D board and/or 3D solid on one beat timeline) with the engine. An explainer gets the engine's explainer report (beats, views, one legend). Returns ok, or the exact refusal reason (one stable token) and part. An accepted document gives parts, triangles, steps (v2 captions filled from facts), solved gear ratios, mesh and gear checks, and a ref for later calls. An accepted report, and one refused by a post-compile check (open mesh, gear overlap, strict), also has the engine's honesty data: warnings, facts (value, unit, text, truth tier, source), the tier legend, stepTiers, stepFacts, partTiers, motionTiers, notChecked, sectionTriangles and readBack (each part's world position, motion and frame in plain words: compare it with what you meant). Repair from the reason, then check again.",
             properties: ["document": Schema.document, "ref": Schema.ref, "components": Schema.components, "strict": Schema.strict],
             required: [], readOnly: true),
        Tool(name: "component_check", title: "Check a component definition",
             description: "Validate a new component definition, compile it alone, instantiate it with `with` values and run the engine checks. Returns the catalog entry and a ready `use` entry.",
             properties: ["definition": ["anyOf": Schema.objectOrString, "description": "The component definition (at most 16 KiB)."],
                          "with": ["type": "object", "additionalProperties": ["type": "number"], "description": "Parameter values."],
                          "components": Schema.components],
             required: ["definition"], readOnly: true),
        Tool(name: "patch", title: "Patch a document",
             description: "Apply an engine patch ({params, parts (merge by id; null removes a field), constraints, steps, title}) to a document and check the result. Use it for what-if questions. Returns the new check result and its ref.",
             properties: ["document": Schema.document, "ref": Schema.ref,
                          "patch": ["anyOf": Schema.objectOrString, "description": "The patch (at most 16 KiB)."],
                          "return_document": ["type": "boolean", "description": "Also return the patched document (default false)."],
                          "components": Schema.components, "strict": Schema.strict],
             required: ["patch"], readOnly: true),
        Tool(name: "render", title: "Render a document",
             description: "Render an accepted document: hero.png, exploded.png, one captioned still per step, snapshot.json and manifest.json (and loop.gif when loop is true). Returns the output directory and every file with its SHA-256 digest. A document that the engine refuses in the plain profile (also check.meshOpen or check.gearsInterpenetrate) is not rendered; the result is its check report. render does not use the strict profile, so it renders a document that check refuses only for joint.idle or frame.axis.off.",
             properties: ["document": Schema.document, "ref": Schema.ref, "components": Schema.components,
                          "size": ["type": "string", "pattern": "^[0-9]{3,4}x[0-9]{3,4}$", "description": "WIDTHxHEIGHT (default 1280x800; at most 1920x1200)."],
                          "loop": ["type": "boolean", "description": "Also render a 12-second loop GIF (120 frames; slower). Default false."]],
             required: [], readOnly: false),
        Tool(name: "lesson_check", title: "Check a beat-by-beat lesson",
             description: "Check a whole lesson document (MartyGraphics lesson v1: a 2D scene and up to 24 beats, each with a spoken line, commands and checks) in a fresh engine session. All or nothing: a refusal gives the reason and its location (beat, statement, command). An accepted lesson gives each beat's line with {placeholders} filled from engine values, and the final board (values, controls).",
             properties: ["lesson": ["anyOf": Schema.objectOrString, "description": "The lesson document (at most 64 KiB; the engine's statement stream limit is 32 KiB)."]],
             required: ["lesson"], readOnly: true),
        Tool(name: "lesson_stream", title: "Stream lesson statements",
             description: "Feed lesson statements (one JSON object per statement: lesson header, scene, keep, say, op, check, end; any split) into a server-held session. Each complete statement is validated at once; a refused statement changes nothing and later ones continue, except that a false check refuses its whole beat (later statements of that beat are refused as beat.refused). After the stream budget (32 KiB or 256 statements) is used up, input is ignored until end (reason lesson.stream.exhausted). Returns the events of this call (accepted, refused with reason, lineQueued with filled text, beatPresented, streamEnded) and the board. Omit `session` to start a new one; `end` ends the stream.",
             properties: ["session": ["type": "string", "maxLength": 128, "description": "A session id from an earlier result (the server keeps the last 8)."],
                          "chunk": ["type": "string", "description": "Statement text, at most 32 KiB per call."],
                          "end": ["type": "boolean", "description": "End the stream and present every complete beat (default false)."]],
             required: ["chunk"], readOnly: false),
    ]

    /// Runs one tool. A `ToolError` is a wrong request; any other result (also a refusal) is a normal result.
    @MainActor static func call(_ name: String, _ given: [String: Any], engine: MartyEngine) throws -> [String: Any] {
        guard let tool = all.first(where: { $0.name == name }) else { throw ToolError("tool.unknown", String(name.prefix(64))) }
        // Some clients send null for every optional argument; null means "not given".
        let args = given.filter { !($0.value is NSNull) }
        let allowed = Set(tool.properties.keys)
        if let extra = args.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw ToolError("args.unknown.\(token(extra))")
        }
        for key in tool.required where args[key] == nil { throw ToolError("args.missing.\(key)") }
        let components = try list(args["components"], "components")
        switch name {
        case "catalog":
            return try engine.catalog(compact: try bool(args["compact"], "compact") ?? true, components: components)
        case "explain":
            return try engine.explain(id: try string(args["id"], "id")!, components: components)
        case "check":
            return try engine.check(document: args["document"], ref: try string(args["ref"], "ref"), components: components,
                                    strict: try bool(args["strict"], "strict") ?? true)
        case "component_check":
            return try engine.componentCheck(definition: args["definition"]!, with: try numbers(args["with"], "with"), components: components)
        case "patch":
            return try engine.patch(document: args["document"], ref: try string(args["ref"], "ref"), patch: args["patch"]!,
                                    components: components, returnDocument: try bool(args["return_document"], "return_document") ?? false,
                                    strict: try bool(args["strict"], "strict") ?? true)
        case "lesson_check":
            return try engine.lessonCheck(lesson: args["lesson"]!)
        case "lesson_stream":
            guard let chunk = args["chunk"] as? String else { throw ToolError("args.type.chunk", "a string") }
            return try engine.lessonStream(session: try string(args["session"], "session"), chunk: chunk, end: try bool(args["end"], "end") ?? false)
        case "render":
            return try engine.render(document: args["document"], ref: try string(args["ref"], "ref"), components: components,
                                     size: try string(args["size"], "size"), loop: try bool(args["loop"], "loop") ?? false)
        default:
            throw ToolError("tool.unknown", name)
        }
    }

    /// A caller-supplied name inside a reason: ASCII letters, digits, `_` and `.` only (others become `_`), at most 32.
    static func token(_ s: String) -> String {
        String(s.unicodeScalars.prefix(32).map { u -> Character in
            u.isASCII && (CharacterSet.alphanumerics.contains(u) || u == "_" || u == ".") ? Character(u) : "_"
        })
    }

    static func string(_ v: Any?, _ key: String) throws -> String? {
        guard let v else { return nil }
        // JSON Schema maxLength counts code points, so count Unicode scalars (not characters or bytes).
        guard let s = v as? String, s.unicodeScalars.count <= MartyLimits.idLength else {
            throw ToolError("args.type.\(key)", "a string of at most \(MartyLimits.idLength) characters")
        }
        return s
    }

    static func bool(_ v: Any?, _ key: String) throws -> Bool? {
        guard let v else { return nil }
        // JSONSerialization gives NSNumber for both numbers and booleans; accept only real booleans.
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw ToolError("args.type.\(key)", "true or false") }
        return n.boolValue
    }

    static func list(_ v: Any?, _ key: String) throws -> [Any] {
        guard let v else { return [] }
        guard let a = v as? [Any] else { throw ToolError("args.type.\(key)", "an array") }
        return a
    }

    static func numbers(_ v: Any?, _ key: String) throws -> [String: Double] {
        guard let v else { return [:] }
        guard let o = v as? [String: Any], o.count <= 32 else { throw ToolError("args.type.\(key)", "an object of at most 32 numbers") }
        var out: [String: Double] = [:]
        for (k, x) in o {
            guard let n = x as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
                throw ToolError("args.type.\(key)", "every value is a finite number")
            }
            out[k] = n.doubleValue
        }
        return out
    }
}
