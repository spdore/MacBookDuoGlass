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
    // Smoothed physical lid speed in degrees per second. The fragment shader
    // uses this only for a short motion-scattering contribution while the
    // lid is moving.
    var motionSpeed: Float
}

final class DuoMetalView: MTKView, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private var latestPixelBuffer: CVPixelBuffer?
    private var parameters = EffectState(angle: 90, isValid: true, isClear: true, projectionOnly: false, intensity: 0, perspectiveDegrees: 0, blurPixels: 0, darken: 0, milk: 0, grain: 0)
    private var startTime = CACurrentMediaTime()
    private let inFlight = DispatchSemaphore(value: 2)
    private var fpsWindowStart = CACurrentMediaTime()
    private var submittedFrames = 0
    private let frostBlur = FrostBlur()
    private var filteredBuffer: CVPixelBuffer?
    private var filteredIntensity: Float = -1
    private var filteredTextures: [MTLTexture]?
    private var renderAngle = RenderAngle()
    private var preparedSize: CGSize = .zero
    private var preparing = false
    private var prepareGeneration = 0
    private var firstFramePending = true
    private var visibilityGeneration = 0
    private var lastRenderedAngle: Double?
    private var lastRenderedTime: CFTimeInterval?
    private var smoothedMotionSpeed: Float = 0

    // Run allocation and first MPS dispatch while the desktop is still clear.
    func prepare(_ pixelBuffer: CVPixelBuffer) {
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        guard !preparing, preparedSize != size,
              let reference = makeTexture(from: pixelBuffer),
              let source = CVMetalTextureGetTexture(reference),
              let command = commandQueue.makeCommandBuffer() else { return }
        let generation = prepareGeneration
        preparing = true
        guard frostBlur.encode(source: source, strength: 0.01, maxSigma: 48, command: command) != nil else {
            preparing = false
            return
        }
        filteredIntensity = -1
        command.addCompletedHandler { [weak self] finished in
            withExtendedLifetime((reference, pixelBuffer)) {}
            let succeeded = finished.status == .completed
            DispatchQueue.main.async {
                guard let self else { return }
                self.preparing = false
                guard self.prepareGeneration == generation else { return }
                if succeeded { self.preparedSize = size }
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
        lastRenderedAngle = nil
        lastRenderedTime = nil
        smoothedMotionSpeed = 0
        visibilityGeneration += 1
        firstFramePending = true
    }

    func releaseFrameResources() {
        prepareGeneration &+= 1
        latestPixelBuffer = nil
        filteredBuffer = nil
        filteredTextures = nil
        filteredIntensity = -1
        preparedSize = .zero
        resetAngleTransition()
    }

    func draw(in view: MTKView) {
        guard !preparing, preparedSize != .zero else { return }
        let now = CACurrentMediaTime()
        let displayedAngle = renderAngle.value(at: now) ?? self.parameters.angle
        updateMotionSpeed(angle: displayedAngle, time: now)
        // Evaluate continuous Double angles at display cadence. The hardware
        // can still report integers; no rounding is introduced here.
        let parameters = EffectModel.state(
            angle: displayedAngle,
            isValid: self.parameters.isValid,
            projectionOnly: self.parameters.projectionOnly)
        guard inFlight.wait(timeout: .now()) == .success else { return }
        var submitted = false
        defer { if !submitted { inFlight.signal() } }
        guard let pixelBuffer = latestPixelBuffer,
              let textureRef = makeTexture(from: pixelBuffer),
              let texture = CVMetalTextureGetTexture(textureRef),
              let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // Reuse filtered images while both the capture frame and angle are
        // unchanged. All writes and reads run on this same serial GPU queue.
        if filteredBuffer !== pixelBuffer || filteredIntensity != parameters.intensity {
            guard let images = frostBlur.encode(source: texture, strength: parameters.intensity,
                maxSigma: parameters.blurPixels, command: commandBuffer) else { return }
            filteredTextures = images
            filteredBuffer = pixelBuffer
            filteredIntensity = parameters.intensity
        }
        guard let images = filteredTextures,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setFragmentTexture(images[0], index: 0)
        encoder.setFragmentTexture(images[1], index: 1)

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
                time: Float(now - startTime),
                motionSpeed: smoothedMotionSpeed
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
        let fpsNow = CACurrentMediaTime()
        if fpsNow - fpsWindowStart >= 1 {
            NSLog("Duo render: %d submitted frames/s", submittedFrames)
            fpsWindowStart = fpsNow
            submittedFrames = 0
        }
    }

    private func updateMotionSpeed(angle: Double, time: CFTimeInterval) {
        defer {
            lastRenderedAngle = angle
            lastRenderedTime = time
        }
        guard let previousAngle = lastRenderedAngle,
              let previousTime = lastRenderedTime else {
            smoothedMotionSpeed = 0
            return
        }
        let deltaTime = time - previousTime
        guard deltaTime > 0, deltaTime < 0.25 else {
            smoothedMotionSpeed = 0
            return
        }
        // The render angle is already eased over 40 ms. A second, faster
        // low-pass keeps the shader response continuous without making a
        // single sensor sample produce a visible jump.
        let rawSpeed = min(abs(angle - previousAngle) / deltaTime, 1440)
        let response = 1 - exp(-deltaTime / 0.06)
        smoothedMotionSpeed += (Float(rawSpeed) - smoothedMotionSpeed) * Float(response)
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
        float motionSpeed;
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
        texture2d<float, access::sample> source [[texture(0)]],
        texture2d<float, access::sample> strongBlur [[texture(1)]],
        constant DuoUniforms &u [[buffer(0)]]) {
        constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);

        float2 outputUV = in.uv;
        // modelY is the normalized distance from the hinge: 0 at the hinge,
        // 1 at the far edge of the folded display.
        float modelY = clamp(1.0 - outputUV.y, 0.0, 1.0);
        float phi = u.perspectiveDegrees * 0.017453292519943295;
        float sinPhi = sin(phi);
        float cosPhi = cos(phi);
        float foldAmount = clamp(abs(sinPhi), 0.0, 1.0);
        float yGlass = modelY * cosPhi;
        float zGlass = modelY * sinPhi;
        float3 eye = float3(0.0, 0.5, 2.5);
        float3 glassPoint = float3((outputUV.x - 0.5) * u.aspect, yGlass, zGlass);
        float denominator = glassPoint.z - eye.z;
        float lambda = denominator == 0.0 ? -1.0 : -eye.z / denominator;
        float3 intersection = eye + lambda * (glassPoint - eye);
        // Keep the unbounded coordinate for the edge mask, then clamp only
        // the texture lookup. This makes projected regions fade to real black
        // instead of smearing the nearest edge pixel across the screen.
        float2 projectedUV = float2(intersection.x / max(u.aspect, 0.001) + 0.5,
                                    1.0 - intersection.y);
        float2 sourceUV = clamp(projectedUV, float2(0.0), float2(1.0));

        float verticalGradient = 0.35 + 0.65 * modelY;
        // The sharp and blurred buffers use the SAME projected coordinate.
        // The blur mix therefore remains a glass material response and never
        // creates the old displaced double-image artifact.
        float4 sharpSample = source.sample(linearSampler, sourceUV);
        float4 blurSample = strongBlur.sample(linearSampler, sourceUV);
        float4 color = mix(sharpSample, blurSample, modelY);

        // 1) Distance-dependent transmission. Light is transmitted most
        // strongly near the hinge and attenuates toward the free edge.
        float opticalDistance = modelY * (0.35 + 0.65 * foldAmount);
        float distanceTransmission = exp(-0.65 * opticalDistance);
        float transmissionAmount = foldAmount * u.intensity * (0.18 + 0.38 * u.intensity);
        float transmission = mix(1.0, distanceTransmission,
                                 clamp(transmissionAmount, 0.0, 0.62));
        color.rgb *= transmission;

        // 7) Motion scattering. RenderAngle supplies a smoothed degrees/sec
        // value, so this is active only during a real lid movement and fades
        // out continuously instead of toggling per sensor sample.
        float motionFactor = smoothstep(60.0, 520.0, abs(u.motionSpeed));
        float motionRadius = (0.0015 + 0.0055 * modelY) * motionFactor *
                              u.intensity;
        if (motionRadius > 0.00001) {
            float2 motionOffset = float2(0.0, motionRadius);
            float4 motionA = mix(source.sample(linearSampler,
                                               clamp(sourceUV - motionOffset,
                                                     float2(0.0), float2(1.0))),
                                  strongBlur.sample(linearSampler,
                                                    clamp(sourceUV - motionOffset,
                                                          float2(0.0), float2(1.0))),
                                  modelY);
            float4 motionB = mix(source.sample(linearSampler,
                                               clamp(sourceUV + motionOffset,
                                                     float2(0.0), float2(1.0))),
                                  strongBlur.sample(linearSampler,
                                                    clamp(sourceUV + motionOffset,
                                                          float2(0.0), float2(1.0))),
                                  modelY);
            float motionBlend = 0.10 * motionFactor * u.intensity;
            color.rgb = mix(color.rgb, 0.5 * (motionA.rgb + motionB.rgb), motionBlend);
        }

        // 4) Small red/blue offsets create chromatic dispersion without
        // shifting the green channel or changing the projected geometry.
        float2 dispersionDirection = normalize(float2((outputUV.x - 0.5) * 0.75,
                                                       -max(modelY, 0.08)));
        float dispersion = 0.0009 * u.intensity * foldAmount * pow(modelY, 1.25);
        if (dispersion > 0.00002) {
            float2 redUV = clamp(sourceUV + dispersionDirection * dispersion,
                                 float2(0.0), float2(1.0));
            float2 blueUV = clamp(sourceUV - dispersionDirection * dispersion,
                                  float2(0.0), float2(1.0));
            float4 redSharp = source.sample(linearSampler, redUV);
            float4 redBlur = strongBlur.sample(linearSampler, redUV);
            float4 blueSharp = source.sample(linearSampler, blueUV);
            float4 blueBlur = strongBlur.sample(linearSampler, blueUV);
            float3 dispersed = color.rgb;
            dispersed.r = mix(redSharp.r, redBlur.r, modelY) * transmission;
            dispersed.b = mix(blueSharp.b, blueBlur.b, modelY) * transmission;
            color.rgb = mix(color.rgb, dispersed, 0.82);
        }

        float shading = u.darken * verticalGradient;
        color.rgb *= 1.0 - shading;
        color.rgb = mix(color.rgb, float3(0.96, 0.97, 1.0), u.milk * verticalGradient);

        // 2) Directional reflection: a view/light-dependent specular term and
        // a broad moving sheen make the surface read as glass rather than a
        // uniform white overlay.
        float3 normal = normalize(float3(0.0, -sinPhi, cosPhi));
        float3 viewDirection = normalize(eye - glassPoint);
        float3 lightDirection = normalize(float3(-0.35, 0.65, 1.0));
        float3 halfDirection = normalize(lightDirection + viewDirection);
        float specular = pow(max(dot(normal, halfDirection), 0.0), 28.0);
        float fresnel = pow(1.0 - max(dot(normal, viewDirection), 0.0), 3.0);
        float sheenCenter = 0.25 + 0.18 * sin(phi * 1.3);
        float sheen = exp(-pow((outputUV.x - sheenCenter) / 0.28, 2.0));
        float reflectionMask = smoothstep(0.06, 0.92, modelY) *
                               (0.35 + 0.65 * foldAmount);
        float reflection = u.intensity * reflectionMask *
                           (0.026 * specular + 0.012 * fresnel + 0.022 * sheen);
        color.rgb += float3(0.82, 0.92, 1.0) * reflection;

        // 1) Narrow contact highlight where the glass meets the hinge.
        float contactBand = 1.0 - smoothstep(0.0, 0.085, modelY);
        float contactSpecular = pow(max(dot(normal, viewDirection), 0.0), 6.0);
        float contact = u.intensity * foldAmount * contactBand *
                        (0.018 + 0.035 * contactSpecular);
        color.rgb += float3(0.86, 0.94, 1.0) * contact;

        // 5) True fade to black as the projected surface recedes from the
        // hinge. The mask is based on the unbounded projection, so out-of-
        // bounds pixels also become black instead of edge-clamped copies.
        float signedEdgeDistance = min(min(projectedUV.x, 1.0 - projectedUV.x),
                                       min(projectedUV.y, 1.0 - projectedUV.y));
        float edgeFeather = (0.004 + 0.026 * u.intensity) *
                            (0.70 + 0.30 * modelY);
        // A steep fold can place the whole projected plane a small distance
        // beyond the source rectangle. Using a narrow signed-edge smoothstep
        // here would turn every pixel black at roughly 79°. Give the outside
        // region a perceptual falloff instead: shallow overshoot remains a
        // translucent edge, while a genuinely distant projection still fades
        // to black.
        float outsideDepth = max(-signedEdgeDistance, 0.0);
        float outsideFadeRange = 0.20 + 0.20 * foldAmount *
                                 (0.65 + 0.35 * u.intensity);
        float insideShape = 0.66 +
                            0.34 * smoothstep(0.0, edgeFeather,
                                              max(signedEdgeDistance, 0.0));
        float outsideShape = 0.66 *
                             (1.0 - smoothstep(0.0, outsideFadeRange,
                                               outsideDepth));
        float edgeShape = signedEdgeDistance >= 0.0 ? insideShape : outsideShape;
        float edgeActivation = smoothstep(0.001, 0.18, u.intensity);

        // 6) Softened glass edge. It activates gradually so the clear state
        // remains pixel-identical at the selected threshold.
        float edgeCoverage = mix(1.0, edgeShape, edgeActivation);
        float distanceFade = smoothstep(0.18, 1.0, modelY);
        float blackFade = clamp(0.32 * u.intensity * foldAmount * distanceFade,
                                0.0, 0.72);
        color.rgb *= edgeCoverage * (1.0 - blackFade);

        float noise = (hash21(outputUV * 1024.0 + float2(u.time)) - 0.5) * u.grain;
        color.rgb += noise * edgeCoverage;
        color.a = 1.0;
        return color;
    }
    """
}
