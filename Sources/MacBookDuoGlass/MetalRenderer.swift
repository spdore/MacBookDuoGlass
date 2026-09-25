import AppKit
import CoreVideo
import Metal
import MetalKit
import QuartzCore

struct DuoUniforms {
    var intensity: Float
    var perspectiveDegrees: Float
    var blurPixels: Float
    var darken: Float
    var milk: Float
    var grain: Float
    var aspect: Float
    var time: Float
}

final class DuoMetalView: MTKView, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private var latestPixelBuffer: CVPixelBuffer?
    private var parameters = EffectState(angle: 90, isValid: true, isClear: true, intensity: 0, perspectiveDegrees: 0, blurPixels: 0, darken: 0, milk: 0, grain: 0)
    private var startTime = CACurrentMediaTime()
    private let inFlight = DispatchSemaphore(value: 2)
    private var fpsWindowStart = CACurrentMediaTime()
    private var submittedFrames = 0
    private let frostBlur = FrostBlur()
    private var filteredBuffer: CVPixelBuffer?
    private var filteredTextures: [MTLTexture]?
    private var renderAngle = RenderAngle()
    private var preparedSize: CGSize = .zero
    private var preparing = false
    private var prepareGeneration = 0
    private var firstFramePending = true
    private var visibilityGeneration = 0

    // Run the first fixed-radius blur while the overlay is still hidden. The
    // result is reused by the first visible draw when this is still the
    // newest captured frame, avoiding a duplicate startup blur.
    func prepare(_ pixelBuffer: CVPixelBuffer) {
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        guard !preparing, preparedSize != size,
              let reference = makeTexture(from: pixelBuffer),
              let source = CVMetalTextureGetTexture(reference),
              let command = commandQueue.makeCommandBuffer() else { return }
        let generation = prepareGeneration
        preparing = true
        guard let images = frostBlur.encode(source: source, strength: 1,
                                            maxSigma: EffectModel.maximumBlurPixels,
                                            command: command) else {
            preparing = false
            return
        }
        command.addCompletedHandler { [weak self, images] finished in
            withExtendedLifetime((reference, pixelBuffer, images)) {}
            let succeeded = finished.status == .completed
            DispatchQueue.main.async {
                guard let self else { return }
                self.preparing = false
                guard self.prepareGeneration == generation else { return }
                if succeeded {
                    self.preparedSize = size
                    self.filteredBuffer = pixelBuffer
                    self.filteredTextures = images
                }
            }
        }
        command.commit()
    }

    init?(duoFrame frame: CGRect) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertex = library.makeFunction(name: "duo_vertex"),
              let fragment = library.makeFunction(name: "duo_fragment") else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            return nil
        }

        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.textureCache = cache
        super.init(frame: frame, device: device)

        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        // Render on the display link. Capture and angle updates only replace
        // the latest inputs; they do not determine presentation cadence.
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 60
        if let metalLayer = layer as? CAMetalLayer {
            // MTKView schedules the draw on the display link; these layer
            // settings make presentation wait for the display refresh and
            // prevent Core Animation transactions from adding a frame.
            metalLayer.displaySyncEnabled = true
            metalLayer.presentsWithTransaction = false
            metalLayer.maximumDrawableCount = 2
        }
        delegate = self
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        autoresizingMask = [.width, .height]
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setFrame(_ pixelBuffer: CVPixelBuffer) {
        latestPixelBuffer = pixelBuffer
        needsDisplay = true
    }

    func setEffectState(_ state: EffectState) {
        parameters = state
        let now = CACurrentMediaTime()
        if renderAngle.value(at: now) == nil {
            renderAngle.update(EffectModel.clearThreshold, at: now)
        }
        renderAngle.update(state.angle, at: now)
        needsDisplay = true
    }

    func resetAngleTransition() {
        renderAngle.reset()
        visibilityGeneration += 1
        firstFramePending = true
    }

    func releaseFrameResources() {
        prepareGeneration &+= 1
        latestPixelBuffer = nil
        filteredBuffer = nil
        filteredTextures = nil
        preparedSize = .zero
        resetAngleTransition()
    }

    func draw(in view: MTKView) {
        guard !preparing, preparedSize != .zero else { return }
        // Evaluate continuous Double angles at display cadence. The hardware
        // can still report integers; no rounding is introduced here.
        let parameters = EffectModel.state(
            angle: renderAngle.value(at: CACurrentMediaTime()) ?? self.parameters.angle,
            isValid: self.parameters.isValid)
        guard inFlight.wait(timeout: .now()) == .success else { return }
        var submitted = false
        defer { if !submitted { inFlight.signal() } }
        guard let pixelBuffer = latestPixelBuffer,
              let textureRef = makeTexture(from: pixelBuffer),
              let texture = CVMetalTextureGetTexture(textureRef),
              let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // Generate the fixed blur layers once per captured frame. Angle
        // changes only update uniforms and are blended in the fragment
        // shader, so moving the lid never recreates MPS filters or dispatches
        // another full-screen Gaussian pass.
        if filteredBuffer !== pixelBuffer {
            guard let images = frostBlur.encode(source: texture, strength: 1,
                maxSigma: EffectModel.maximumBlurPixels, command: commandBuffer) else { return }
            filteredTextures = images
            filteredBuffer = pixelBuffer
        }
        guard let images = filteredTextures,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(images[0], index: 1)
        encoder.setFragmentTexture(images[1], index: 2)

        encoder.setRenderPipelineState(pipeline)

        do {
            var uniforms = DuoUniforms(
                intensity: parameters.intensity,
                perspectiveDegrees: parameters.perspectiveDegrees,
                blurPixels: parameters.blurPixels,
                darken: parameters.darken,
                milk: parameters.milk,
                grain: parameters.grain,
                aspect: Float(drawableSize.width / max(drawableSize.height, 1)),
                time: Float(CACurrentMediaTime() - startTime)
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DuoUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        // Core Video owns the IOSurface: retain BOTH references until GPU completion.
        let semaphore = inFlight
        let generation = visibilityGeneration
        commandBuffer.addCompletedHandler { [weak self] finished in
            withExtendedLifetime((textureRef, pixelBuffer)) {}
            semaphore.signal()
            let succeeded = finished.status == .completed
            DispatchQueue.main.async {
                guard succeeded, let self, !self.isPaused,
                      generation == self.visibilityGeneration,
                      self.firstFramePending else { return }
                self.firstFramePending = false
                self.window?.alphaValue = 1
            }
        }
        submitted = true
        commandBuffer.commit()
        submittedFrames += 1
        let now = CACurrentMediaTime()
        if now - fpsWindowStart >= 1 {
            NSLog("Duo render: %d submitted frames/s", submittedFrames)
            fpsWindowStart = now
            submittedFrames = 0
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> CVMetalTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var textureRef: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &textureRef
        )
        guard result == kCVReturnSuccess, let textureRef else { return nil }
        return textureRef
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct DuoUniforms {
        float intensity;
        float perspectiveDegrees;
        float blurPixels;
        float darken;
        float milk;
        float grain;
        float aspect;
        float time;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut duo_vertex(uint vertexID [[vertex_id]]) {
        const float2 positions[4] = {
            float2(-1.0, -1.0), float2(1.0, -1.0),
            float2(-1.0, 1.0), float2(1.0, 1.0)
        };
        // The capture buffer is top-left oriented. The output vertices are
        // arranged so uv is identity when the fold intensity is zero.
        const float2 uvs[4] = {
            float2(0.0, 1.0), float2(1.0, 1.0),
            float2(0.0, 0.0), float2(1.0, 0.0)
        };
        VertexOut out;
        out.position = float4(positions[vertexID], 0.0, 1.0);
        out.uv = uvs[vertexID];
        return out;
    }

    float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    fragment float4 duo_fragment(
        VertexOut in [[stage_in]],
        texture2d<float, access::sample> sharpSource [[texture(0)]],
        texture2d<float, access::sample> weakBlur [[texture(1)]],
        texture2d<float, access::sample> strongBlur [[texture(2)]],
        constant DuoUniforms &u [[buffer(0)]]) {
        constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);

        float2 outputUV = in.uv;
        float modelY = 1.0 - outputUV.y;
        float phi = u.perspectiveDegrees * 0.017453292519943295;
        float yGlass = modelY * cos(phi);
        float zGlass = modelY * sin(phi);
        float3 eye = float3(0.0, 0.5, 2.5);
        float3 glassPoint = float3((outputUV.x - 0.5) * u.aspect, yGlass, zGlass);
        float denominator = glassPoint.z - eye.z;
        float lambda = denominator == 0.0 ? -1.0 : -eye.z / denominator;
        float3 intersection = eye + lambda * (glassPoint - eye);
        float2 sourceUV = float2(intersection.x / max(u.aspect, 0.001) + 0.5, 1.0 - intersection.y);
        sourceUV = clamp(sourceUV, float2(0.0), float2(1.0));

        float verticalGradient = 0.35 + 0.65 * modelY;
        // All layers use the same reprojected coordinate. The angle-driven
        // intensity is a cheap continuous mix; the expensive Gaussian layers
        // were generated once for this captured frame before this pass.
        float3 sharp = sharpSource.sample(linearSampler, sourceUV).rgb;
        float3 medium = weakBlur.sample(linearSampler, sourceUV).rgb;
        float3 diffuse = strongBlur.sample(linearSampler, sourceUV).rgb;
        float3 frosted = mix(medium, diffuse, verticalGradient);
        float blurMix = clamp(u.intensity, 0.0, 1.0);
        float3 color = mix(sharp, frosted, blurMix);

        float shading = u.darken * verticalGradient;
        color *= 1.0 - shading;
        color = mix(color, float3(0.96, 0.97, 1.0), u.milk * verticalGradient);
        float noise = (hash21(outputUV * 1024.0) - 0.5) * u.grain;
        color += noise;
        return float4(color, 1.0);
    }
    """
}
