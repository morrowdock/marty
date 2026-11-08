// SPDX-License-Identifier: Apache-2.0
import AppKit
import CoreText
import Foundation
import ImageIO
import MartyGraphics
import UniformTypeIdentifiers

/// Renders an accepted document into a new directory under the output root: the same sequence as `marty-solid render`
/// at the pinned engine commit (hero, exploded, one captioned still per step, optional 12-second loop GIF, snapshot,
/// manifest). The directory name comes from a digest of the inputs, so the same request reuses the same result.
extension MartyEngine {
    public func render(document: Any?, ref: String?, components: [Any], size: String?, loop: Bool) throws -> [String: Any] {
        guard let root = outputRoot else { throw ToolError("render.disabled", "this server was started with --no-render") }
        var width = 1280, height = 800
        if let s = size {
            guard let p = Self.parseSize(s) else { throw ToolError("args.size", "size is WIDTHxHEIGHT, width 320-1920 and height 200-1200") }
            (width, height) = p
        }
        let lib: MGSolidLibrary
        switch try library(components) { case .failure(let r): return r.report; case .success(let l): lib = l }
        let json: MGJSON
        switch try resolve(document: document, ref: ref) {
        case .failure(let r): return ["ok": false, "reason": r.reason, "part": NSNull()]
        case .success(let j): json = j
        }
        if Self.isExplainer(json) {
            throw ToolError("render.explainer", "marty-mcp renders assemblies only; render an explainer with marty-solid render")
        }
        let (report, compiled) = checkJSON(json, lib)
        guard let doc = compiled, (report["ok"] as? Bool) == true else { return report }
        let docRef = report["ref"] as! String

        let componentKeys = try components.map { c -> String in
            guard case .success(let j) = Decode.json(c, limit: MartyLimits.componentBytes, tooLarge: "component.bytes") else {
                throw ToolError("args.components")
            }
            return MartyJSON.ref(j)
        }
        let key = MartyJSON.sha256(Data(([MartyPin.engineRevision, Self.renderFormat, docRef, "\(width)x\(height)", loop ? "loop" : "still"] + componentKeys)
            .joined(separator: "\n").utf8))
        let name = "render-" + key.prefix(20)
        let out = root.appendingPathComponent(name, isDirectory: true)
        let manifestURL = out.appendingPathComponent("manifest.json")
        /// A finished render of the same request: its own manifest, as written.
        func reused() -> [String: Any]? {
            guard let data = try? Data(contentsOf: manifestURL), let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let outputs = m["outputs"] as? [Any] else { return nil }
            return ["ok": true, "ref": docRef, "directory": out.path, "reused": true,
                    "files": outputs + [["file": "manifest.json", "bytes": data.count, "sha256": MartyJSON.sha256(data)]]]
        }
        if let r = reused() { return r }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tmp = root.appendingPathComponent(".partial-\(key.prefix(20))-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: false)
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: tmp) } }

        let started = Date()
        let sourceName = "document " + docRef.prefix(19)
        let source = MGSolidSource(data: json.canonicalData)
        let result = try Self.renderFiles(doc, sourceName: sourceName, source: source, into: tmp, width: width, height: height, loop: loop)
        // The engine's manifest (`MGSolidRenderPlan.manifest`), with Marty's render format and ref beside it.
        // Every file record must convert; never drop one silently.
        let outputs = try result.files.map { f -> MGJSON in
            guard let j = MGJSON(any: f) else { throw ToolError("render.manifest", "a file record could not be encoded") }
            return j
        }
        guard case .object(var m) = try MGSolidRenderPlan.manifest(doc, sourceName: sourceName, source: source, framesRendered: result.frames,
                                                                   secondsPerFrame: result.frames > 0 ? result.seconds / Double(result.frames) : 0,
                                                                   outputs: outputs, engine: Self.engineIdentity) else { throw ToolError("render.manifest") }
        m["format"] = .string(Self.renderFormat)
        m["ref"] = .string(docRef)
        let manifestData = Self.MJ(MGJSON.object(m))
        try manifestData.write(to: tmp.appendingPathComponent("manifest.json"))
        do { try FileManager.default.moveItem(at: tmp, to: out) }
        catch {
            // Another process finished the same render first: remove our copy and return the files that are there.
            guard let r = reused() else { throw error }
            try? FileManager.default.removeItem(at: tmp)
            finished = true
            return r
        }
        finished = true
        let files = result.files + [["file": "manifest.json", "bytes": manifestData.count, "sha256": MartyJSON.sha256(manifestData)]]
        return ["ok": true, "ref": docRef, "directory": out.path, "files": files, "reused": false,
                "timing": ["seconds": Date().timeIntervalSince(started), "framesRendered": result.frames,
                           "renderSecondsPerFrame": result.frames > 0 ? result.seconds / Double(result.frames) : 0]]
    }

    /// `WIDTHxHEIGHT` in ASCII digits within the render bounds, or nil.
    public nonisolated static func parseSize(_ s: String) -> (Int, Int)? {
        let parts = s.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.unicodeScalars.allSatisfy { ("0"..."9").contains($0) } }),
              let w = Int(parts[0]), let h = Int(parts[1]),
              MartyLimits.renderWidth.contains(w), MartyLimits.renderHeight.contains(h) else { return nil }
        return (w, h)
    }

    /// Changes whenever Marty's render sequence or manifest changes, so an old result is never reused for a new format.
    public static let renderFormat = "marty-render/3"

    /// Takes the engine's render plan (`MGSolidRenderPlan`): captioned stills, the optional loop GIF and the snapshot.
    static func renderFiles(_ doc: MGSolidDocument, sourceName: String, source: MGSolidSource, into out: URL, width: Int, height: Int,
                            loop: Bool) throws -> (files: [[String: Any]], frames: Int, seconds: Double) {
        _ = NSApplication.shared
        let r = MGSolidRenderer(document: doc)
        let aspect = Double(width) / Double(height)
        let plan = MGSolidRenderPlan(doc, sourceName: sourceName, source: source, loop: loop)
        var files: [[String: Any]] = []
        var seconds = 0.0, frames = 0
        var previousFrame: MGAnnotationFrame?
        func shot(_ s: MGSolidShot) throws -> CGImage {
            let p = MGSolidCamera.presets[s.preset] ?? MGSolidCamera.presets["hero"]!
            // As marty-solid render: each step shows its own section cuts, ghosts and annotations; annotations show on
            // hero.png and the step stills only (`MGSolidShot.showsAnnotations`), and only where the engine checked
            // the pose (inside the renderer and the frame).
            let view = doc.view(step: s.step)
            if s.showsAnnotations { r.show(document: doc, view: view) } else { r.show(view) }
            r.highlight(Set(s.highlight), dimOthers: !s.highlight.isEmpty)
            r.apply(s.params)
            r.frame(s.params, explodeRange: [0, s.params.explode], yaw: p.yaw + s.orbit, pitch: p.pitch, aspect: aspect, margin: s.margin)
            let t0 = Date()
            guard let img = r.render(width: width, height: height) else { throw ToolError("render.metal", "no Metal device") }
            seconds += Date().timeIntervalSince(t0); frames += 1
            guard s.showsAnnotations, !view.annotations.isEmpty else { return img }
            let frame = MGSolidAnnotations.frame(document: doc, view: view, params: s.params, camera: r.camera, width: Double(width),
                                                 height: Double(height), previous: previousFrame, highlight: s.highlight,
                                                 caption: s.caption != nil, title: true)
            previousFrame = frame
            return Self.overlaid(img, frame, doc)
        }
        func record(_ name: String, _ fields: [String: Any]) throws {
            let d = try Data(contentsOf: out.appendingPathComponent(name))
            files.append(fields.merging(["file": name, "bytes": d.count, "sha256": MartyJSON.sha256(d)]) { a, _ in a })
        }
        for s in plan.stills {
            previousFrame = nil
            let img = caption(try shot(s), title: s.title ?? doc.title, text: s.caption, footer: plan.footer)
            try writePNG(img, out.appendingPathComponent(s.file))
            try record(s.file, ["width": img.width, "height": img.height])
        }
        if !plan.loop.isEmpty {
            let n = plan.loop.count, gifURL = out.appendingPathComponent("loop.gif"), delay = MGSolidRenderPlan.loopDelaySeconds
            guard let gif = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, n, nil) else { throw ToolError("render.gif") }
            CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for s in plan.loop {
                CGImageDestinationAddImage(gif, scaled(try shot(s), width: MGSolidRenderPlan.loopWidth),
                                           [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
            }
            guard CGImageDestinationFinalize(gif) else { throw ToolError("render.gif") }
            try record("loop.gif", ["width": MGSolidRenderPlan.loopWidth, "frames": n, "delaySeconds": delay, "loopSeconds": MGSolidRenderPlan.loopSeconds])
        }
        try MGSolidRenderPlan.snapshot(doc).jsonData().write(to: out.appendingPathComponent("snapshot.json"))
        try record("snapshot.json", [:])
        return (files, frames, seconds)
    }

    /// Sorted-key JSON of an engine value.
    static func MJ(_ j: MGJSON) -> Data { MartyJSON.data(j.any) }

    /// The engine's annotation overlay (labels, leaders, value texts, callouts, legend) over a rendered frame.
    static func overlaid(_ image: CGImage, _ frame: MGAnnotationFrame, _ doc: MGSolidDocument) -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        MGSolidOverlay.draw(frame, document: doc, legend: true, in: ctx, width: w, height: h)
        return ctx.makeImage() ?? image
    }

    static func caption(_ image: CGImage, title: String, text: String?, footer: String) -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let s = CGFloat(w) / 1280
        func attributed(_ str: String, _ size: CGFloat, _ weight: NSFont.Weight, alpha: CGFloat) -> NSAttributedString {
            NSAttributedString(string: str, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight) as CTFont,
                                                         .foregroundColor: NSColor(white: 1, alpha: alpha).cgColor])
        }
        // The title stays on one line; a long title ends with an ellipsis.
        let line = CTLineCreateWithAttributedString(attributed(title, 28 * s, .semibold, alpha: 1))
        let dots = CTLineCreateWithAttributedString(attributed("…", 28 * s, .semibold, alpha: 1))
        ctx.textPosition = CGPoint(x: 40 * s, y: CGFloat(h) - 64 * s)
        CTLineDraw(CTLineCreateTruncatedLine(line, Double(CGFloat(w) - 80 * s), .end, dots) ?? line, ctx)
        if let t = text {
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.55)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: Int(120 * s)))
            let setter = CTFramesetterCreateWithAttributedString(attributed(t, 20 * s, .regular, alpha: 0.95))
            let path = CGPath(rect: CGRect(x: 40 * s, y: 30 * s, width: CGFloat(w) - 80 * s, height: 80 * s), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), ctx)
        }
        ctx.textPosition = CGPoint(x: 40 * s, y: CGFloat(h) - 92 * s)
        CTLineDraw(CTLineCreateWithAttributedString(attributed(footer, 12 * s, .regular, alpha: 0.6)), ctx)
        return ctx.makeImage() ?? image
    }

    static func writePNG(_ image: CGImage, _ url: URL) throws {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ToolError("render.png") }
        CGImageDestinationAddImage(d, image, nil)
        guard CGImageDestinationFinalize(d) else { throw ToolError("render.png") }
    }

    static func scaled(_ image: CGImage, width: Int) -> CGImage {
        let h = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
        guard let ctx = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.interpolationQuality = .high; ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: h))
        return ctx.makeImage() ?? image
    }
}
