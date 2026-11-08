// SPDX-License-Identifier: Apache-2.0
import Foundation
import MartyGraphics

/// The engine tools behind the MCP server. Each method takes decoded tool arguments and returns a JSON object.
/// Every number in a result comes from the MartyGraphics engine; this type only bounds inputs and shapes reports.
/// A library refusal, carried as a result report.
struct Refused: Error { let report: [String: Any]; init(_ r: [String: Any]) { report = r } }

@MainActor
public final class MartyEngine {
    /// Where `render` writes. `nil` turns `render` off.
    public let outputRoot: URL?
    private var cache: [(ref: String, json: MGJSON)] = []
    /// Lesson stream sessions (`lesson_stream`), least recently used first, at most `maxLessonSessions`.
    var lessonSessions: [(id: String, session: MGLessonSession, exhausted: Bool)] = []
    var lessonSessionCounter = 0

    public init(outputRoot: URL?) { self.outputRoot = outputRoot }

    // MARK: document references

    func remember(_ json: MGJSON) -> String {
        let ref = MartyJSON.ref(json)
        cache.removeAll { $0.ref == ref }
        cache.append((ref, json))
        if cache.count > MartyLimits.cachedDocuments { cache.removeFirst(cache.count - MartyLimits.cachedDocuments) }
        return ref
    }

    /// Exactly one of `document` and `ref`. An input refusal (too large, not JSON) is returned as a result.
    func resolve(document: Any?, ref: String?) throws -> Result<MGJSON, InputRefusal> {
        switch (document, ref) {
        case (nil, nil): throw ToolError("args.document", "send `document` (a JSON object or string) or `ref`")
        case (_?, _?): throw ToolError("args.document", "send `document` or `ref`, not both")
        case (let d?, nil): return Decode.json(d, limit: MartyLimits.documentBytes, tooLarge: "assembly.bytes")
        case (nil, let r?):
            guard let hit = cache.last(where: { $0.ref == r }) else {
                throw ToolError("cache.miss", "this server does not hold \(r.prefix(80)); send the full document again")
            }
            return .success(hit.json)
        }
    }

    /// The canonical JSON text of a held document, or nil when this engine does not hold `ref`.
    public func canonicalDocument(ref: String) -> String? {
        cache.last(where: { $0.ref == ref })?.json.canonicalString
    }

    // MARK: library

    /// The built-in components plus extra definitions, registered in order (a later one may use an earlier one).
    func library(_ definitions: [Any]) throws -> Result<MGSolidLibrary, Refused> {
        guard definitions.count <= MartyLimits.componentsPerRequest else {
            throw ToolError("args.components.count", "at most \(MartyLimits.componentsPerRequest) component definitions")
        }
        var lib = MGSolidLibrary.builtIn
        for (i, def) in definitions.enumerated() {
            switch Decode.json(def, limit: MartyLimits.componentBytes, tooLarge: "component.bytes") {
            case .failure(let r): return .failure(Refused(["ok": false, "reason": r.reason, "part": NSNull(), "component": i]))
            case .success(let json):
                if case .failure(let issue) = lib.register(json: json) {
                    return .failure(Refused(["ok": false, "reason": issue.reason, "part": issue.part as Any, "component": i]))
                }
            }
        }
        return .success(lib)
    }

    // MARK: check

    /// The engine identity in every report: the engine's own (`MGEngine.identity`) plus the commit Marty is pinned to.
    static var engineIdentity: MGJSON {
        guard case .object(var o) = MGEngine.identity else { return MGEngine.identity }
        o["revision"] = .string(MartyPin.engineRevision)
        return .object(o)
    }

    /// The engine's check report (`MGSolidReport`, exactly what `marty-solid check [--strict]` prints for the same
    /// document), plus Marty's `partIds`. `file` describes the canonical JSON that Marty checked.
    static func report(_ doc: MGSolidDocument, strict: Bool = false, json: MGJSON? = nil) -> [String: Any] {
        let source = json.map { MGSolidSource(data: $0.canonicalData) }
        let r = MGSolidReport.make(doc, profile: strict ? .strict : .standard, source: source, engine: engineIdentity)
        var out = plain(r.json) ?? ["ok": false, "reason": "report.encoding"]
        if out["part"] == nil { out["part"] = NSNull() }
        out["partIds"] = doc.assembly.parts.map(\.id)
        return out
    }

    static func refusedReport(_ issue: MGSolidIssue, strict: Bool, json: MGJSON?) -> [String: Any] {
        let source = json.map { MGSolidSource(data: $0.canonicalData) }
        let r = MGSolidReport.refused(issue, profile: strict ? .strict : .standard, source: source, engine: engineIdentity)
        return plain(r.json) ?? ["ok": false, "reason": issue.reason]
    }

    /// An engine report as Foundation JSON values (numbers as NSNumber, as an MCP client reads them), so in-process
    /// callers see the same types as clients do.
    static func plain(_ j: MGJSON) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: j.canonicalData)) as? [String: Any]
    }

    /// True for an explainer document (`kind: "explainer"`, MartyGraphics docs/EXPLAINER.md).
    public nonisolated static func isExplainer(_ json: MGJSON) -> Bool { json["kind"] == .string("explainer") }

    /// The engine's explainer report (`MGExplainerReport`, exactly `marty-solid check [--strict]` on an explainer), plus
    /// Marty's convenience copies from its 3D view for the loop: `steps` (the beat captions), `stepTiers`, `facts`,
    /// `ratios`, `readBack`, `partIds`. The engine's own fields are unchanged.
    static func explainerReport(_ json: MGJSON, _ lib: MGSolidLibrary, strict: Bool) -> [String: Any] {
        let r = MGExplainerReport.check(data: json.canonicalData, library: lib, profile: strict ? .strict : .standard, engine: engineIdentity)
        var out = plain(r.json) ?? ["ok": false, "reason": "report.encoding"]
        if out["part"] == nil { out["part"] = NSNull() }
        if let beats = out["beats"] as? [[String: Any]] {
            out["steps"] = beats.map { $0["caption"] ?? NSNull() }
            out["stepTiers"] = beats.map { $0["tier"] ?? NSNull() }
        }
        if let solid = (out["views"] as? [String: Any])?["solid"] as? [String: Any] {
            for k in ["facts", "ratios", "readBack"] { if let v = solid[k] { out[k] = v } }
        }
        if let ids = (out["ids"] as? [String: Any])?["solid"] { out["partIds"] = ids }
        return out
    }

    func checkJSON(_ json: MGJSON, _ lib: MGSolidLibrary, strict: Bool = false) -> (report: [String: Any], doc: MGSolidDocument?) {
        let ref = remember(json)
        if Self.isExplainer(json) {
            var r = Self.explainerReport(json, lib, strict: strict)
            r["ref"] = ref
            return (r, nil)
        }
        switch MGSolidParser.document(json: json, library: lib) {
        case .failure(let issue):
            var r = Self.refusedReport(issue, strict: strict, json: json)
            r["ref"] = ref
            return (r, nil)
        case .success(let doc):
            var r = Self.report(doc, strict: strict, json: json)
            r["ref"] = ref
            return (r, doc)
        }
    }

    /// `strict` is the engine's model-harness profile: it also refuses idle joints and turn axes that miss their part.
    public func check(document: Any?, ref: String?, components: [Any], strict: Bool = false) throws -> [String: Any] {
        let lib: MGSolidLibrary
        switch try library(components) { case .failure(let r): return r.report; case .success(let l): lib = l }
        switch try resolve(document: document, ref: ref) {
        case .failure(let r): return ["ok": false, "reason": r.reason, "part": NSNull(), "strict": strict]
        case .success(let json): return checkJSON(json, lib, strict: strict).report
        }
    }

    // MARK: component check

    public func componentCheck(definition: Any, with values: [String: Double], components: [Any]) throws -> [String: Any] {
        var lib: MGSolidLibrary
        switch try library(components) { case .failure(let r): return r.report; case .success(let l): lib = l }
        let json: MGJSON
        switch Decode.json(definition, limit: MartyLimits.componentBytes, tooLarge: "component.bytes") {
        case .failure(let r): return ["ok": false, "reason": r.reason, "part": NSNull()]
        case .success(let j): json = j
        }
        let component: MGSolidComponent
        switch lib.register(json: json) {
        case .failure(let issue): return ["ok": false, "reason": issue.reason, "part": issue.part as Any]
        case .success(let c): component = c
        }
        switch lib.instantiate(component.id, with: values) {
        case .failure(let issue):
            return ["ok": false, "reason": issue.reason, "part": issue.part as Any, "id": component.id, "with": values]
        case .success(let doc):
            let r = Self.report(doc)
            let used = Dictionary(uniqueKeysWithValues: component.params.map { ($0.name, values[$0.name] ?? $0.defaultValue) })
            return ["ok": r["ok"]!, "reason": r["reason"]!, "part": NSNull(), "id": component.id, "with": used,
                    "catalogEntry": component.catalogEntry.any,
                    "use": ["id": "a", "use": component.id, "with": used],
                    "instance": ["parts": r["parts"]!, "triangles": r["triangles"]!, "ratios": r["ratios"]!, "checks": r["checks"]!],
                    "source": ["bytes": json.canonicalData.count, "sha256": MartyJSON.sha256(json.canonicalData)]]
        }
    }

    // MARK: patch

    public func patch(document: Any?, ref: String?, patch: Any, components: [Any], returnDocument: Bool, strict: Bool = false) throws -> [String: Any] {
        let lib: MGSolidLibrary
        switch try library(components) { case .failure(let r): return r.report; case .success(let l): lib = l }
        let base: MGJSON
        switch try resolve(document: document, ref: ref) {
        case .failure(let r): return ["ok": false, "reason": r.reason, "part": NSNull(), "strict": strict, "stage": "base"]
        case .success(let j): base = j
        }
        // The engine has no patch format for explainers (docs/EXPLAINER.md); send the whole changed document to check.
        if Self.isExplainer(base) { throw ToolError("patch.explainer", "explainer documents cannot be patched; send the changed document to check") }
        let p: MGJSON
        switch Decode.json(patch, limit: MartyLimits.patchBytes, tooLarge: "patch.bytes") {
        case .failure(let r): return ["ok": false, "reason": r.reason, "part": NSNull(), "strict": strict, "stage": "patch"]
        case .success(let j): p = j
        }
        let baseRef = remember(base)
        let doc: MGSolidDocument
        switch MGSolidParser.document(json: base, library: lib) {
        case .failure(let issue):
            // The same refusal shape as `check` of that base, plus where it happened.
            var r = Self.refusedReport(issue, strict: strict, json: base)
            r["stage"] = "base"; r["baseRef"] = baseRef
            return r
        case .success(let d): doc = d
        }
        switch MGSolidParser.applying(p, to: doc) {
        case .failure(let issue):
            // The engine refused the patch; the base document is unchanged.
            var r = Self.refusedReport(issue, strict: strict, json: base)
            r["stage"] = "patch"; r["baseRef"] = baseRef
            return r
        case .success(let patched):
            // The engine already compiled the patched document; report on it without compiling it again.
            let ref = remember(patched.source)
            var r = Self.report(patched, strict: strict, json: patched.source)
            r["ref"] = ref
            r["baseRef"] = baseRef
            if returnDocument { r["document"] = patched.source.any }
            return r
        }
    }

    // MARK: catalog and explain

    public func catalog(compact: Bool, components: [Any]) throws -> [String: Any] {
        let lib: MGSolidLibrary
        switch try library(components) { case .failure(let r): return r.report; case .success(let l): lib = l }
        var primitives: [String: Any] = [:]
        for kind in MartyPrimitive.Kind.allCases {
            let list = MartyPrimitive.all.filter { $0.kind == kind }
            primitives[kind.plural] = compact ? list.map(\.id) as Any : list.map { $0.summary(full: false) } as Any
        }
        primitives["cameras"] = MGSolidCamera.presets.keys.sorted()
        var out: [String: Any] = [
            "ok": true,
            "engine": ["repository": MartyPin.engineRepository, "revision": MartyPin.engineRevision],
            "components": lib.catalog().any,
            "primitives": primitives,
            "limits": ["documentBytes": MGSolidLimits.bytes, "parts": MGSolidLimits.parts, "resolvedParts": MGSolidLimits.resolvedParts,
                       "shapesPerPart": MGSolidLimits.shapesPerPart, "constraints": MGSolidLimits.constraints,
                       "steps": MGSolidLimits.steps, "title": MGSolidLimits.title, "name": MGSolidLimits.name, "say": MGSolidLimits.say,
                       "triangles": MGSolidLimits.triangles],
        ]
        if compact { out["hint"] = "Call explain with an id for keys and a checked example." }
        return out
    }

    public func explain(id: String, components: [Any]) throws -> [String: Any] {
        let lib: MGSolidLibrary
        switch try library(components) { case .failure(let r): return r.report; case .success(let l): lib = l }
        if let c = lib[id] {
            return ["ok": true, "id": id, "type": "component", "entry": c.catalogEntry.any, "definition": c.source.any,
                    "use": ["id": "a", "use": id, "with": [String: Double]()]]
        }
        if let p = MartyPrimitive.all.first(where: { $0.id == id }) {
            var out = p.summary(full: true)
            out["ok"] = true
            out["type"] = "primitive"
            return out
        }
        let known = (lib.ids + MartyPrimitive.all.map(\.id)).sorted()
        return ["ok": false, "reason": "explain.unknown", "id": String(id.prefix(MartyLimits.idLength)), "known": known]
    }
}
