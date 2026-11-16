import AppKit
import CoreGraphics
import Foundation
import Metal

/// Offscreen preview of the shipping pipeline (FrostBlur + duo_fragment) on a
/// synthetic desktop. It needs neither screen-recording permission nor a
/// physical lid movement, so before/after comparisons can be rendered anywhere.
///
///     MacBookDuoGlass --render-preview <output-dir> [--style fold|classic] [--mirror] [width height]
///
/// `--mirror` renders Mirror Mode (projection only, no material effects).
/// Only the generated fixture is drawn; no user screen content is read or saved.
/// The exit code is 0 only when every file was written; any failure is printed
/// to standard error and the process exits non-zero.
enum PreviewRender {
    static let angles: [Double] = [100, 90, 75, 60, 45, 30, 15, 0]

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func run(arguments: [String]) -> Int32 {
        guard arguments.first != nil else {
            print("usage: --render-preview <output-dir> [--style fold|classic] [--mirror] [width height]")
            return 2
        }
        do {
            return try generate(arguments: arguments)
        } catch {
            FileHandle.standardError.write(Data("Preview failed: \(error)\n".utf8))
            return 1
        }
    }

    private static func generate(arguments: [String]) throws -> Int32 {
        var arguments = arguments
        let outputPath = arguments.removeFirst()
        var fold = true
        if let flag = arguments.firstIndex(of: "--style"), flag + 1 < arguments.count {
            fold = arguments[flag + 1] != "classic"
            arguments.removeSubrange(flag...(flag + 1))
        }
        var mirror = false
        if let flag = arguments.firstIndex(of: "--mirror") {
            mirror = true
            arguments.remove(at: flag)
        }
        let width = arguments.count >= 2 ? Int(arguments[0]) ?? 1440 : 1440
        let height = arguments.count >= 2 ? Int(arguments[1]) ?? 932 : 932
        let directory = URL(fileURLWithPath: outputPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw Failure("cannot create \(directory.path): \(error.localizedDescription)")
        }

        guard let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeLibrary(source: DuoMetalView.shaderSource, options: nil),
              let queue = device.makeCommandQueue() else {
            throw Failure("no Metal device")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let source = device.makeTexture(descriptor: descriptor),
              let output = device.makeTexture(descriptor: descriptor) else {
            throw Failure("cannot allocate \(width)x\(height) textures")
        }

        var fixture = [UInt8](repeating: 0, count: width * height * 4)
        drawDesktop(into: &fixture, width: width, height: height)
        fixture.withUnsafeBytes {
            source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "duo_vertex")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: fold ? "duo_fragment_fold" : "duo_fragment")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor) else {
            throw Failure("cannot build the render pipeline")
        }
        let blur = FrostBlur()

        func render(angle: Double, motionSpeed: Float) -> CGImage? {
            let state = EffectModel.state(angle: angle, projectionOnly: mirror)
            guard let command = queue.makeCommandBuffer(),
                  let images = blur.encode(source: source, strength: state.intensity,
                                           maxSigma: state.blurPixels, command: command) else { return nil }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(images[0], index: 0)
            encoder.setFragmentTexture(images[1], index: 1)
            var uniforms = DuoUniforms(state: state, aspect: Float(width) / Float(height),
                                       time: 0, motionSpeed: motionSpeed)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DuoUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else { return nil }
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes {
                output.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            return makeImage(&bytes, width: width, height: height)
        }

        var tiles: [(String, CGImage)] = []
        for angle in angles {
            guard let image = render(angle: angle, motionSpeed: 0) else {
                throw Failure("render failed at \(Int(angle))°")
            }
            try write(image, to: directory.appendingPathComponent("angle-\(Int(angle)).png"))
            tiles.append(("\(Int(angle))°", image))
        }
        // One moving-lid frame, so the motion-scattering term can be compared too.
        guard let moving = render(angle: 60, motionSpeed: 420) else {
            throw Failure("render failed at 60° moving")
        }
        try write(moving, to: directory.appendingPathComponent("angle-60-moving.png"))
        tiles.append(("60° moving", moving))
        guard let sheet = contactSheet(tiles, tileWidth: 720, tileHeight: 720 * height / width) else {
            throw Failure("cannot compose the contact sheet")
        }
        try write(sheet, to: directory.appendingPathComponent("contact-sheet.png"))
        let styleName = fold ? "fold plane" : "classic glass"
        print("Preview written to \(directory.path) (\(tiles.count) frames, \(width)x\(height), \(styleName)\(mirror ? ", mirror mode" : ""))")
        return 0
    }

    // MARK: Fixture

    private static func makeContext(_ bytes: UnsafeMutableRawPointer, width: Int, height: Int) -> CGContext? {
        CGContext(data: bytes, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    private static func makeImage(_ bytes: inout [UInt8], width: Int, height: Int) -> CGImage? {
        bytes.withUnsafeMutableBytes { makeContext($0.baseAddress!, width: width, height: height)?.makeImage() }
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw Failure("cannot encode \(url.lastPathComponent) as PNG")
        }
        do {
            try png.write(to: url)
        } catch {
            throw Failure("cannot write \(url.path): \(error.localizedDescription)")
        }
    }

    /// A stand-in desktop: gradient wallpaper, menu bar, two windows with
    /// text and a colour strip, and a dock. Colour blocks make the geometry
    /// readable; small text makes the blur readable.
    private static func drawDesktop(into bytes: inout [UInt8], width: Int, height: Int) {
        bytes.withUnsafeMutableBytes { raw in
            guard let context = makeContext(raw.baseAddress!, width: width, height: height) else { return }
            let w = CGFloat(width), h = CGFloat(height)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

            NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.42, alpha: 1),
                                NSColor(calibratedRed: 0.55, green: 0.24, blue: 0.62, alpha: 1),
                                NSColor(calibratedRed: 0.96, green: 0.56, blue: 0.40, alpha: 1)])?
                .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: 35)

            NSColor(white: 1, alpha: 0.78).setFill()
            NSRect(x: 0, y: h - 28, width: w, height: 28).fill()
            for (index, title) in ["", "Finder", "File", "Edit", "View", "Go", "Window", "Help"].enumerated() {
                (title as NSString).draw(at: NSPoint(x: 14 + CGFloat(index) * 74, y: h - 22),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: index == 1 ? .bold : .regular),
                                     .foregroundColor: NSColor.black])
            }

            func window(_ rect: NSRect, title: String, accent: NSColor, lines: [String]) {
                let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
                NSColor(white: 0.97, alpha: 1).setFill()
                path.fill()
                accent.setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.maxY - 34, width: rect.width, height: 34),
                             xRadius: 12, yRadius: 12).fill()
                NSColor(white: 0.97, alpha: 1).setFill()
                NSRect(x: rect.minX, y: rect.maxY - 34, width: rect.width, height: 14).fill()
                accent.setFill()
                NSRect(x: rect.minX, y: rect.maxY - 34, width: rect.width, height: 34).fill()
                for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                    color.setFill()
                    NSBezierPath(ovalIn: NSRect(x: rect.minX + 14 + CGFloat(i) * 22, y: rect.maxY - 25, width: 14, height: 14)).fill()
                }
                (title as NSString).draw(at: NSPoint(x: rect.minX + 100, y: rect.maxY - 27),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white])
                for (i, line) in lines.enumerated() {
                    (line as NSString).draw(at: NSPoint(x: rect.minX + 24, y: rect.maxY - 70 - CGFloat(i) * 30),
                        withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 17, weight: .regular),
                                         .foregroundColor: NSColor(white: 0.1, alpha: 1)])
                }
            }
            window(NSRect(x: 70, y: h * 0.22, width: w * 0.46, height: h * 0.62), title: "Notes",
                   accent: NSColor(calibratedRed: 0.95, green: 0.62, blue: 0.10, alpha: 1),
                   lines: ["The quick brown fox jumps over", "the lazy dog 0123456789", "MacBook Duo Glass preview",
                           "perspective follows the lid angle", "fine text shows how blur grows", "away from the hinge",
                           "— — — — — — — — — — — — —", "func render(angle: Double) {", "    let phi = angle * .pi / 180",
                           "    return project(phi)", "}"])
            window(NSRect(x: w * 0.40, y: h * 0.12, width: w * 0.52, height: h * 0.60), title: "Terminal",
                   accent: NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.28, alpha: 1),
                   lines: ["$ swift build -c release", "Compiling MetalRenderer.swift", "Build complete! (12.41s)",
                           "$ ./scripts/build_app.sh", "Built dist/MacBookDuoGlass.app", "$ _"])

            NSColor(white: 1, alpha: 0.30).setFill()
            let dock = NSRect(x: w * 0.5 - 300, y: 12, width: 600, height: 76)
            NSBezierPath(roundedRect: dock, xRadius: 22, yRadius: 22).fill()
            let palette: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPink, .systemPurple, .systemTeal, .systemRed, .systemIndigo]
            for (i, color) in palette.enumerated() {
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: dock.minX + 14 + CGFloat(i) * 72, y: 24, width: 56, height: 56),
                             xRadius: 13, yRadius: 13).fill()
            }
        }
    }

    private static func contactSheet(_ tiles: [(String, CGImage)], tileWidth: Int, tileHeight: Int) -> CGImage? {
        let columns = 3
        let rows = (tiles.count + columns - 1) / columns
        let gap = 16
        let sheetWidth = columns * tileWidth + (columns + 1) * gap
        let sheetHeight = rows * (tileHeight + 30) + (rows + 1) * gap
        var bytes = [UInt8](repeating: 0, count: sheetWidth * sheetHeight * 4)
        return bytes.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = makeContext(raw.baseAddress!, width: sheetWidth, height: sheetHeight) else { return nil }
            context.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))
            context.interpolationQuality = .high
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for (index, tile) in tiles.enumerated() {
                let column = index % columns, row = index / columns
                let x = gap + column * (tileWidth + gap)
                let y = sheetHeight - (gap + (row + 1) * (tileHeight + 30) + row * gap) + 0
                context.draw(tile.1, in: CGRect(x: x, y: y, width: tileWidth, height: tileHeight))
                (tile.0 as NSString).draw(at: NSPoint(x: x + 4, y: y - 24),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white])
            }
            return context.makeImage()
        }
    }
}
