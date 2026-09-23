import AppKit
import CoreGraphics
import Foundation
import Metal
import QuartzCore

enum SelfTest {
    static func run() -> Int32 {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let savedThreshold = EffectModel.clearThreshold
        EffectModel.clearThreshold = EffectModel.defaultThreshold
        defer { EffectModel.clearThreshold = savedThreshold }

        guard EffectModel.clampThreshold(74) == 75,
              EffectModel.clampThreshold(121) == 120,
              EffectModel.clampThreshold(97) == 97 else {
            print("Threshold range: failed")
            return 1
        }
        print("Threshold range: 75°–120° (ok)")

        let at100 = EffectModel.state(angle: 100).intensity
        let at0 = EffectModel.state(angle: 0).intensity
        let mappingOK = abs(at100 - 0.0) < 0.0001 && abs(at0 - 1.0) < 0.0001
        print(String(format: "Angle mapping: 100°=%.2f, 0°=%.2f (%@)", at100, at0, mappingOK ? "ok" : "failed"))
        guard mappingOK else { return 1 }
        var previous: Float = 1
        for angle in stride(from: 0.0, through: 100.0, by: 0.5) {
            let state = EffectModel.state(angle: angle)
            guard state.intensity <= previous,
                  abs(state.intensity - Float(1 - angle / 100)) < 0.00001,
                  (0..<120).allSatisfy({ _ in EffectModel.state(angle: angle).intensity == state.intensity })
            else { print("Angle stability: failed"); return 1 }
            previous = state.intensity
        }
        guard EffectModel.state(angle: 100).isClear,
              EffectModel.state(angle: 100.01).isClear,
              !EffectModel.state(angle: .nan).isValid else { return 1 }
        print("Angle sweep and stationary-angle stability: ok")
        var transition = RenderAngle()
        transition.update(90, at: 0)
        transition.update(89, at: 1)
        guard let halfway = transition.value(at: 1.02),
              abs(halfway - 89.5) < 0.00001 else { return 1 }
        transition.update(89, at: 1.025) // duplicate samples must not prolong it
        guard transition.value(at: 1.05) == 89,
              transition.value(at: 5) == 89 else { return 1 }
        transition.update(88, at: 6)
        let beforeReversal = transition.value(at: 6.02)
        transition.update(90, at: 6.02)
        guard transition.value(at: 6.02) == beforeReversal,
              transition.value(at: 6.07) == 90 else { return 1 }
        transition.reset()
        transition.update(75, at: 7)
        guard transition.value(at: 7) == 75 else { return 1 }
        transition.reset()
        transition.update(EffectModel.clearThreshold, at: 8)
        transition.update(99, at: 8)
        guard transition.value(at: 8) == 100,
              abs((transition.value(at: 8.02) ?? 0) - 99.5) < 0.00001,
              transition.value(at: 8.05) == 99 else { return 1 }
        print("Continuous render angle: fractional, bounded settling, reversal and reset (ok)")

        guard let device = MTLCreateSystemDefaultDevice() else {
            print("Metal pipeline: no default device")
            return 1
        }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: DuoMetalView.shaderSource, options: nil)
        } catch {
            print("Metal pipeline: shader compile failed: \(error)")
            return 1
        }
        guard library.makeFunction(name: "duo_vertex") != nil,
              library.makeFunction(name: "duo_fragment") != nil else {
            print("Metal pipeline: failed")
            return 1
        }
        print("Metal pipeline: ok")
        guard testRendering(device: device, library: library) else { return 1 }
        benchmarkRendering(device: device, library: library)
        let permissionText = CGPreflightScreenCaptureAccess() ? "granted" : "denied"
        print("Screen capture permission: \(permissionText)")

        let sensor = LidAngleSensor()
        var samples: [AngleSample] = []
        sensor.start { sample in
            if samples.count < 30 {
                samples.append(sample)
            }
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        sensor.stop()
        let validSamples = samples.filter(\.isValid)
        if let latest = validSamples.last {
            let minimum = validSamples.map(\.degrees).min() ?? latest.degrees
            let maximum = validSamples.map(\.degrees).max() ?? latest.degrees
            print(String(format: "Lid sensor: ok (latest=%.2f°, range=%.2f°–%.2f°, samples=%d)", latest.degrees, minimum, maximum, validSamples.count))
        } else if !samples.isEmpty {
            print("Lid sensor: found but did not return a valid report")
        } else {
            print("Lid sensor: no report within 500 ms")
        }
        return 0
    }

    // Exercise the same Gaussian filters and perspective shader as the app.
    // No screen recording or overlay is involved in this regression test.
    private static func testRendering(device: MTLDevice, library: MTLLibrary) -> Bool {
        let size = 512
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let source = device.makeTexture(descriptor: descriptor),
              let output = device.makeTexture(descriptor: descriptor),
              let queue = device.makeCommandQueue() else { return false }
        var fixture = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let value: UInt8 = (x / 8) % 2 == 0 ? 0 : 255
                for c in 0..<3 { fixture[(y * size + x) * 4 + c] = value }
            }
        }
        fixture.withUnsafeBytes {
            source.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: size * 4)
        }
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "duo_vertex")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "duo_fragment")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor) else { return false }
        let blur = FrostBlur()
        func render(_ angle: Double, isolateBlur: Bool = false) -> [UInt8]? {
            let state = EffectModel.state(angle: angle)
            guard let command = queue.makeCommandBuffer() else { return nil }
            guard let images = blur.encode(source: source, strength: state.intensity,
                maxSigma: state.blurPixels, command: command) else { return nil }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(images[0], index: 0)
            encoder.setFragmentTexture(images[1], index: 1)
            var uniforms = DuoUniforms(intensity: state.intensity, perspectiveDegrees: isolateBlur ? 0 : state.perspectiveDegrees,
                blurPixels: state.blurPixels, darken: isolateBlur ? 0 : state.darken, milk: isolateBlur ? 0 : state.milk,
                grain: isolateBlur ? 0 : state.grain, aspect: 1, time: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DuoUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else { return nil }
            var bytes = [UInt8](repeating: 0, count: size * size * 4)
            bytes.withUnsafeMutableBytes {
                output.getBytes($0.baseAddress!, bytesPerRow: size * 4,
                                from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
            }
            return bytes
        }
        guard let mild = render(100), let strong = render(0),
              mild != strong else { print("GPU strength response: failed"); return false }
        // Changing strength and returning to the same angle must reproduce every pixel.
        for _ in 0..<12 {
            guard render(100) == mild else { print("GPU stationary output: failed"); return false }
        }
        print("GPU render: distinct strengths; repeated 100° output identical after 0° (ok)")
        // A thin line must spread into ONE continuous lobe. Sparse offset
        // sampling creates separated replicas and fails this regression.
        for y in 0..<size {
            for x in 0..<size {
                for c in 0..<3 { fixture[(y * size + x) * 4 + c] = x == size / 2 ? 255 : 0 }
            }
        }
        fixture.withUnsafeBytes {
            source.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: size * 4)
        }
        guard let line = render(45, isolateBlur: true) else { return false }
        let center = size / 2
        func value(_ x: Int) -> Int { Int(line[(center * size + x) * 4]) }
        for distance in 1...20 {
            guard value(center - distance) > 0, value(center + distance) > 0,
                  value(center - distance) <= value(center - distance + 1),
                  value(center + distance) <= value(center + distance - 1)
            else { print("Gaussian single-lobe regression: failed"); return false }
        }
        print("Gaussian single-lobe regression: no separated replicas (ok)")
        // Synthetic text/grid preview; no user screen content is saved.
        fixture.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: size, height: size).fill()
            NSColor.lightGray.setStroke()
            for coordinate in stride(from: 0, through: size, by: 32) {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: coordinate, y: 0))
                path.line(to: NSPoint(x: coordinate, y: size))
                path.move(to: NSPoint(x: 0, y: coordinate))
                path.line(to: NSPoint(x: size, y: coordinate))
                path.stroke()
            }
            for (index, text) in ["FROST GLASS", "Single image, soft edges", "0123456789", "Angle controls strength"].enumerated() {
                (text as NSString).draw(at: NSPoint(x: 40, y: 430 - index * 100),
                    withAttributes: [.font: NSFont.systemFont(ofSize: index == 0 ? 34 : 24, weight: .semibold),
                                     .foregroundColor: NSColor.black])
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        fixture.withUnsafeBytes {
            source.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: size * 4)
        }
        for angle in [100.0, 90, 60] {
            guard var preview = render(angle) else { return false }
            preview.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: size, height: size,
                    bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                    let image = context.makeImage(),
                    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                else { return }
                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("duoglass-quality-\(Int(angle)).png")
                try? png.write(to: outputURL)
            }
        }
        print("Synthetic text/grid previews were written to the system temporary directory.")
        return true
    }

    private static func benchmarkRendering(device: MTLDevice, library: MTLLibrary) {
        let displayID = CGMainDisplayID()
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return }
        let width = max(mode.pixelWidth, 128)
        let height = max(mode.pixelHeight, 128)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .renderTarget]
        guard let source = device.makeTexture(descriptor: descriptor),
              let output = device.makeTexture(descriptor: descriptor),
              let queue = device.makeCommandQueue() else {
            print("GPU 60 Hz benchmark: unavailable")
            return
        }
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "duo_vertex")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "duo_fragment")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor) else {
            print("GPU 60 Hz benchmark: pipeline unavailable")
            return
        }

        let state = EffectModel.state(angle: 45)
        // Initialize the source; the old benchmark sampled an undefined texture
        // and excluded filtering and presentation costs.
        guard let initial = queue.makeCommandBuffer() else { return }
        let clear = MTLRenderPassDescriptor()
        clear.colorAttachments[0].texture = source
        clear.colorAttachments[0].loadAction = .clear
        clear.colorAttachments[0].storeAction = .store
        clear.colorAttachments[0].clearColor = MTLClearColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)
        initial.makeRenderCommandEncoder(descriptor: clear)?.endEncoding()
        initial.commit()
        initial.waitUntilCompleted()
        let blur = FrostBlur()
        let frameCount = 120
        let start = CACurrentMediaTime()
        var lastCommand: MTLCommandBuffer?
        for _ in 0..<frameCount {
            guard let command = queue.makeCommandBuffer() else { return }
            guard let images = blur.encode(source: source, strength: state.intensity,
                maxSigma: state.blurPixels, command: command) else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(images[0], index: 0)
            encoder.setFragmentTexture(images[1], index: 1)
            var uniforms = DuoUniforms(intensity: state.intensity, perspectiveDegrees: state.perspectiveDegrees,
                blurPixels: state.blurPixels, darken: state.darken, milk: state.milk,
                grain: state.grain, aspect: Float(width) / Float(height), time: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DuoUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            command.commit()
            lastCommand = command
        }
        lastCommand?.waitUntilCompleted()
        let elapsed = max(CACurrentMediaTime() - start, 0.0001)
        let fps = Double(frameCount) / elapsed
        print(String(format: "Offscreen Gaussian + perspective: %.1f fps @ %dx%d (%@; excludes capture/presentation)", fps, width, height, fps >= 60 ? "ok" : "below target"))
    }
}
