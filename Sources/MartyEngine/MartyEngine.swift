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

    /// Engine checks beyond parsing: closed meshes and a gear tooth sweep, as `marty-solid check` runs them.
    /// (Copied from the engine's example CLI at the pinned commit; see docs/DESIGN-MCP.md, "What the engine should own".)
    static func checks(_ doc: MGSolidDocument) -> [String: Any] {
        let open = doc.assembly.parts.filter { !$0.mesh.edgeReport.isClosed }.map(\.id).sorted()
        var out: [String: Any] = ["meshesClosed": open.isEmpty, "openMeshes": open]
        let report = MGSolidChecks.gearMeshes(doc, samples: 96, inputRange: 0...(2 * .pi))
        out["gearPairs"] = report.pairs
        if report.pairs > 0 {
            let module = doc.gears.values.compactMap { $0.spur?.module ?? $0.ring?.module }.min() ?? 1
            let tolerance = MGSolidLimits.toothOverlap * module
            out["maxPenetrationMM"] = report.maxPenetration
            out["minClearanceMM"] = report.minClearance
            out["toleranceMM"] = tolerance
            out["gearsEngage"] = report.maxPenetration <= tolerance
        }
        return out
    }

    /// The report for a compiled document. `reason` is set when a post-parse check fails.
    static func report(_ doc: MGSolidDocument) -> [String: Any] {
        let c = checks(doc)
        var reason: String? = nil
        if (c["meshesClosed"] as? Bool) != true { reason = "check.meshOpen" }
        else if (c["gearsEngage"] as? Bool) == false { reason = "check.gearsInterpenetrate" }
        return ["ok": reason == nil, "reason": reason as Any, "part": NSNull(), "title": doc.title,
                "parts": doc.assembly.parts.count, "partIds": doc.assembly.parts.map(\.id),
                "triangles": doc.assembly.parts.reduce(0) { $0 + $1.mesh.triangleCount },
                "steps": doc.steps.map(\.say), "ratios": doc.ratios, "checks": c]
    }

    func checkJSON(_ json: MGJSON, _ lib: MGSolidLibrary) -> (report: [String: Any], doc: MGSolidDocument?) {
        let ref = remember(json)
        let source: [String: Any] = ["bytes": json.canonicalData.count, "sha256": String(ref.dropFirst(7))]
        switch MGSolidParser.document(json: json, library: lib) {
        case .failure(let issue):
            return (["ok": false, "reason": issue.reason, "part": issue.part as Any, "ref": ref, "source": source], nil)
        case .success(let doc):
            var r = Self.report(doc)
            r["ref"] = ref; r["source"] = source
            return (r, doc)
        }
    }

    public func check(document: Any?, ref: String?, components: [Any]) throws -> [String: Any] {
        let lib: MGSolidLibrary
        switch try library(components) { case .failure(let r): return r.report; case .success(let l): lib = l }
        switch try resolve(document: document, ref: ref) {
        case .failure(let r): return ["ok": false, "reason": r.reason, "part": NSNull()]
        case .success(let json): return checkJSON(json, lib).report
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

    public func patch(document: Any?, ref: String?, patch: Any, components: [Any], returnDocument: Bool) throws -> [String: Any] {
        let lib: MGSolidLibrary
        switch try library(components) { case .failure(let r): return r.report; case .success(let l): lib = l }
        let base: MGJSON
        switch try resolve(document: document, ref: ref) {
        case .failure(let r): return ["ok": false, "reason": r.reason, "part": NSNull(), "stage": "base"]
        case .success(let j): base = j
        }
        let p: MGJSON
        switch Decode.json(patch, limit: MartyLimits.patchBytes, tooLarge: "patch.bytes") {
        case .failure(let r): return ["ok": false, "reason": r.reason, "part": NSNull(), "stage": "patch"]
        case .success(let j): p = j
        }
        let baseRef = remember(base)
        let doc: MGSolidDocument
        switch MGSolidParser.document(json: base, library: lib) {
        case .failure(let issue):
            return ["ok": false, "reason": issue.reason, "part": issue.part as Any, "stage": "base", "baseRef": baseRef]
        case .success(let d): doc = d
        }
        switch MGSolidParser.applying(p, to: doc) {
        case .failure(let issue):
            // The engine refused the patch; the base document is unchanged.
            return ["ok": false, "reason": issue.reason, "part": issue.part as Any, "stage": "patch", "baseRef": baseRef]
        case .success(let patched):
            var r = checkJSON(patched.source, lib).report
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
