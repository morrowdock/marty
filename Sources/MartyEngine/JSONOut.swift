// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import MartyGraphics

/// The engine commit Marty is built against. A test checks that Package.resolved names the same commit.
public enum MartyPin {
    public static let engineRepository = "https://github.com/morrowdock/martygraphics"
    public static let engineRevision = "70bfc47ad9bbdd3db396037fe450374a5dd497ab"
}

/// Every input Marty accepts has a bound. Inputs over a bound are refused before they are parsed.
public enum MartyLimits {
    /// One JSON-RPC message (one line on standard input).
    public static let requestBytes = 1 << 20
    /// The engine's own document limit (`assembly.bytes`).
    public static let documentBytes = MGSolidLimits.bytes
    /// The engine's own component limit (`component.bytes`).
    public static let componentBytes = MGSolidComponentLimits.bytes
    public static let componentsPerRequest = 8
    public static let patchBytes = 16 * 1024
    /// Documents kept in memory so a caller can send `ref` instead of the full document.
    public static let cachedDocuments = 32
    public static let idLength = 128
    public static let renderWidth = 320...1920
    public static let renderHeight = 200...1200
}

/// A request that is wrong in itself (a missing argument, an unknown ref). A document that the engine refuses is not a
/// `ToolError`: it is a normal result with `ok: false`.
public struct ToolError: Error, Equatable, CustomStringConvertible {
    public let reason: String
    public let detail: String
    public init(_ reason: String, _ detail: String = "") { self.reason = reason; self.detail = detail }
    public var description: String { detail.isEmpty ? reason : "\(reason): \(detail)" }
    public var report: [String: Any] { ["ok": false, "error": reason, "detail": detail] }
}

public enum MartyJSON {
    /// Replace values JSON cannot carry (nil, NaN, infinities) with null, recursively.
    public static func sanitized(_ v: Any?) -> Any {
        switch v {
        case nil: return NSNull()
        // A parsed JSON boolean is an NSNumber that also casts to Double; keep it a boolean.
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): return n
        case let d as Double: return d.isFinite ? d : NSNull()
        case let a as [Any]: return a.map { sanitized($0) }
        case let m as [String: Any]: return m.mapValues { sanitized($0) }
        case let m as [String: Double]: return m.mapValues { sanitized($0) }
        case let o?: return o
        }
    }

    /// Compact, sorted-key JSON. The same value always gives the same bytes.
    public static func data(_ object: Any) -> Data {
        let clean = sanitized(object)
        guard JSONSerialization.isValidJSONObject(clean),
              let d = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return Data(#"{"error":"report.encoding","ok":false}"#.utf8)
        }
        return d
    }

    public static func string(_ object: Any) -> String { String(decoding: data(object), as: UTF8.self) }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `sha256:` and the digest of the canonical (sorted-key, compact) form, so formatting never changes a ref.
    public static func ref(_ json: MGJSON) -> String { "sha256:" + sha256(json.canonicalData) }
}

/// A refusal of the input before the engine sees it, in the engine's own words (`assembly.bytes`, `json`).
struct InputRefusal: Error { let reason: String }

enum Decode {
    /// A tool argument is a JSON object, or a string that holds JSON. A string is measured as sent; an object is
    /// measured in its canonical form.
    static func json(_ value: Any, limit: Int, tooLarge: String) -> Result<MGJSON, InputRefusal> {
        if let s = value as? String {
            let data = Data(s.utf8)
            guard data.count <= limit else { return .failure(InputRefusal(reason: tooLarge)) }
            guard let object = try? JSONSerialization.jsonObject(with: data), let j = MGJSON(any: object) else {
                return .failure(InputRefusal(reason: "json"))
            }
            return .success(j)
        }
        guard value is [String: Any] || value is [Any], let j = MGJSON(any: value) else { return .failure(InputRefusal(reason: "json")) }
        guard j.canonicalData.count <= limit else { return .failure(InputRefusal(reason: tooLarge)) }
        return .success(j)
    }
}
