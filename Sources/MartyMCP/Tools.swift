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
    static let document: [String: Any] = [
        "type": ["object", "string"],
        "description": "A solid assembly document (MartyGraphics format v1) as a JSON object, or a string that holds it. At most 64 KiB.",
    ]
    static let ref: [String: Any] = [
        "type": "string",
        "description": "`ref` from an earlier result (sha256:...), in place of `document`. The server keeps the last 32 documents.",
    ]
    static let components: [String: Any] = [
        "type": "array", "maxItems": MartyLimits.componentsPerRequest,
        "items": ["type": ["object", "string"]],
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
             description: "Check a solid assembly document with the engine. Returns ok, or the exact refusal reason (one stable token) and part. An accepted document gives parts, triangles, steps, solved gear ratios, mesh and gear checks, and a ref for later calls. Repair from the reason, then check again.",
             properties: ["document": Schema.document, "ref": Schema.ref, "components": Schema.components],
             required: [], readOnly: true),
        Tool(name: "component_check", title: "Check a component definition",
             description: "Validate a new component definition, compile it alone, instantiate it with `with` values and run the engine checks. Returns the catalog entry and a ready `use` entry.",
             properties: ["definition": ["type": ["object", "string"], "description": "The component definition (at most 16 KiB)."],
                          "with": ["type": "object", "additionalProperties": ["type": "number"], "description": "Parameter values."],
                          "components": Schema.components],
             required: ["definition"], readOnly: true),
        Tool(name: "patch", title: "Patch a document",
             description: "Apply an engine patch ({params, parts (merge by id; null removes a field), constraints, steps, title}) to a document and check the result. Use it for what-if questions. Returns the new check result and its ref.",
             properties: ["document": Schema.document, "ref": Schema.ref,
                          "patch": ["type": ["object", "string"], "description": "The patch (at most 16 KiB)."],
                          "return_document": ["type": "boolean", "description": "Also return the patched document (default false)."],
                          "components": Schema.components],
             required: ["patch"], readOnly: true),
        Tool(name: "render", title: "Render a document",
             description: "Render an accepted document: hero.png, exploded.png, one captioned still per step, snapshot.json and manifest.json (and loop.gif when loop is true). Returns the output directory and the files with SHA-256 digests. A refused document returns the check result.",
             properties: ["document": Schema.document, "ref": Schema.ref, "components": Schema.components,
                          "size": ["type": "string", "pattern": "^[0-9]{3,4}x[0-9]{3,4}$", "description": "WIDTHxHEIGHT (default 1280x800; at most 1920x1200)."],
                          "loop": ["type": "boolean", "description": "Also render a 12-second loop GIF (120 frames; slower). Default false."]],
             required: [], readOnly: false),
    ]

    /// Runs one tool. A `ToolError` is a wrong request; any other result (also a refusal) is a normal result.
    @MainActor static func call(_ name: String, _ args: [String: Any], engine: MartyEngine) throws -> [String: Any] {
        guard let tool = all.first(where: { $0.name == name }) else { throw ToolError("tool.unknown", String(name.prefix(64))) }
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
            return try engine.check(document: args["document"], ref: try string(args["ref"], "ref"), components: components)
        case "component_check":
            return try engine.componentCheck(definition: args["definition"]!, with: try numbers(args["with"], "with"), components: components)
        case "patch":
            return try engine.patch(document: args["document"], ref: try string(args["ref"], "ref"), patch: args["patch"]!,
                                    components: components, returnDocument: try bool(args["return_document"], "return_document") ?? false)
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
        guard let s = v as? String, s.utf8.count <= MartyLimits.idLength else { throw ToolError("args.type.\(key)", "a string of at most \(MartyLimits.idLength) bytes") }
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
