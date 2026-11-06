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
        guard let root = outputRoot else { throw ToolError("render.disabled", "start the server with --output-dir DIR to render") }
        var width = 1280, height = 800
        if let s = size {
            let p = s.split(separator: "x").compactMap { Int($0) }
            guard p.count == 2, MartyLimits.renderWidth.contains(p[0]), MartyLimits.renderHeight.contains(p[1]) else {
                throw ToolError("args.size", "size is WIDTHxHEIGHT, width 320-1920 and height 200-1200")
            }
            width = p[0]; height = p[1]
        }
        let lib: MGSolidLibrary
        switch try library(components) { case .failure(let r): return r; case .success(let l): lib = l }
        let json: MGJSON
        switch try resolve(document: document, ref: ref) {
        case .failure(let r): return ["ok": false, "reason": r.reason, "part": NSNull()]
        case .success(let j): json = j
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
        let key = MartyJSON.sha256(Data(([MartyPin.engineRevision, docRef, "\(width)x\(height)", loop ? "loop" : "still"] + componentKeys)
            .joined(separator: "\n").utf8))
        let name = "render-" + key.prefix(20)
        let out = root.appendingPathComponent(name, isDirectory: true)
        let manifestURL = out.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifestURL), let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return ["ok": true, "ref": docRef, "directory": out.path, "files": m["outputs"] ?? [], "reused": true]
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tmp = root.appendingPathComponent(".partial-\(key.prefix(20))-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: false)
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: tmp) } }

        let started = Date()
        let result = try Self.renderFiles(doc, ref: docRef, into: tmp, width: width, height: height, loop: loop)
        var manifest: [String: Any] = ["engine": MartyPin.engineRevision, "ref": docRef, "title": doc.title,
                                       "parts": doc.assembly.parts.count, "steps": doc.steps.count,
                                       "checks": report["checks"] ?? [:], "outputs": result.files]
        try MartyJSON.data(manifest).write(to: tmp.appendingPathComponent("manifest.json"))
        do { try FileManager.default.moveItem(at: tmp, to: out) }
        catch {
            // Another process finished the same render first; its result is the same request.
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw error }
        }
        finished = true
        return ["ok": true, "ref": docRef, "directory": out.path, "files": result.files, "reused": false,
                "timing": ["seconds": Date().timeIntervalSince(started), "framesRendered": result.frames,
                           "renderSecondsPerFrame": result.frames > 0 ? result.seconds / Double(result.frames) : 0]]
    }

    static func renderFiles(_ doc: MGSolidDocument, ref: String, into out: URL, width: Int, height: Int, loop: Bool)
        throws -> (files: [[String: Any]], frames: Int, seconds: Double) {
        _ = NSApplication.shared
        let r = MGSolidRenderer(assembly: doc.assembly)
        let aspect = Double(width) / Double(height)
        let footer = "Rendered by the MartyGraphics solid engine (\(MartyPin.engineRevision.prefix(8))) from \(ref.prefix(19))"
        var files: [[String: Any]] = []
        var seconds = 0.0, frames = 0
        func shot(_ params: MGPoseParameters, preset: String, orbit: Double = 0, highlight: [String] = [], margin: Double = 0.8) throws -> CGImage {
            let p = MGSolidCamera.presets[preset] ?? MGSolidCamera.presets["hero"]!
            r.highlight(Set(highlight), dimOthers: !highlight.isEmpty)
            r.apply(params)
            r.frame(params, explodeRange: [0, params.explode], yaw: p.yaw + orbit, pitch: p.pitch, aspect: aspect, margin: margin)
            let t0 = Date()
            guard let img = r.render(width: width, height: height) else { throw ToolError("render.metal", "no Metal device") }
            seconds += Date().timeIntervalSince(t0); frames += 1
            return img
        }
        func save(_ img: CGImage, _ name: String) throws {
            let u = out.appendingPathComponent(name); try writePNG(img, u)
            let d = try Data(contentsOf: u)
            files.append(["file": name, "bytes": d.count, "sha256": MartyJSON.sha256(d), "width": img.width, "height": img.height])
        }
        try save(caption(try shot(doc.defaults, preset: "hero"), title: doc.title, text: nil, footer: footer), "hero.png")
        try save(caption(try shot(MGPoseParameters(input: doc.defaults.input, explode: 1), preset: "hero", margin: 0.92),
                         title: doc.title + " · exploded", text: nil, footer: footer), "exploded.png")
        for (i, step) in doc.steps.enumerated() {
            let params = MGPoseParameters(input: doc.defaults.input + step.spin * 2 * .pi, explode: step.explode ?? doc.defaults.explode)
            let img = try shot(params, preset: step.camera ?? "hero", orbit: step.orbit, highlight: step.highlight)
            try save(caption(img, title: doc.title, text: "\(i + 1). \(step.say)", footer: footer), "step-\(i + 1).png")
        }
        if loop {
            let n = 120, gifURL = out.appendingPathComponent("loop.gif")
            guard let gif = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, n, nil) else { throw ToolError("render.gif") }
            CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for k in 0..<n {
                let t = Double(k) / Double(n)
                let e = t > 0.4 && t < 0.9 ? 0.5 - 0.5 * cos((t - 0.4) / 0.5 * 2 * .pi) : 0
                let img = try shot(MGPoseParameters(input: doc.defaults.input + t * 2 * .pi, explode: e), preset: "hero", orbit: t * 360, margin: 0.86)
                CGImageDestinationAddImage(gif, scaled(img, width: 640),
                                           [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1, kCGImagePropertyGIFUnclampedDelayTime: 0.1]] as CFDictionary)
            }
            guard CGImageDestinationFinalize(gif) else { throw ToolError("render.gif") }
            let d = try Data(contentsOf: gifURL)
            files.append(["file": "loop.gif", "bytes": d.count, "sha256": MartyJSON.sha256(d), "width": 640, "frames": n, "loopSeconds": 12.0])
        }
        let snapURL = out.appendingPathComponent("snapshot.json")
        try MGSolidSnapshot.make(doc.assembly, params: doc.defaults).jsonData().write(to: snapURL)
        let sd = try Data(contentsOf: snapURL)
        files.append(["file": "snapshot.json", "bytes": sd.count, "sha256": MartyJSON.sha256(sd)])
        return (files, frames, seconds)
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
