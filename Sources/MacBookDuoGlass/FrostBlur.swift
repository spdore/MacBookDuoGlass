import Metal
import MetalPerformanceShaders

// Both inputs to the final perspective pass are spatially continuous Gaussian
// images. Never approximate a large blur with distant samples of sharp text.
final class FrostBlur {
    private var textures: [MTLTexture] = []
    private var filters: [MPSImageGaussianBlur] = []
    private var lastSigma: Float = -1

    func encode(source: MTLTexture, strength: Float, maxSigma: Float,
                command: MTLCommandBuffer) -> [MTLTexture]? {
        guard strength > 0 else { return [source, source] }
        let device = source.device
        if textures.first?.width != source.width || textures.first?.height != source.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: source.width, height: source.height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            textures = (0..<2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
        }
        guard textures.count == 2 else { return nil }
        let sigma = max(0.1, maxSigma * strength)
        if sigma != lastSigma {
            filters = [Float(0.35), 1].map {
                let filter = MPSImageGaussianBlur(device: device, sigma: max(0.1, sigma * $0))
                filter.edgeMode = .clamp
                return filter
            }
            lastSigma = sigma
        }
        for index in 0..<2 {
            filters[index].encode(commandBuffer: command, sourceTexture: source, destinationTexture: textures[index])
        }
        return textures
    }
}
