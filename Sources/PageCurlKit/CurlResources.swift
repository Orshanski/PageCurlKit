import Metal

/// A Metal object handed from the queue that made it to the main thread. Metal devices, buffers
/// and textures may be used from any thread.
struct MetalHandle<Object>: @unchecked Sendable {
    let object: Object
}

/// The leaf's grid in GPU memory.
final class LeafMesh: @unchecked Sendable {
    let width: Float
    let height: Float
    let step: Float
    let vertices: MTLBuffer
    let indices: MTLBuffer
    let indexCount: Int

    private init(
        width: Float, height: Float, step: Float, vertices: MTLBuffer, indices: MTLBuffer, indexCount: Int
    ) {
        self.width = width
        self.height = height
        self.step = step
        self.vertices = vertices
        self.indices = indices
        self.indexCount = indexCount
    }

    static func make(device: MTLDevice, width: Float, height: Float, step: Float) -> LeafMesh? {
        let geometry = LeafMeshGeometry(width: width, height: height, step: step)
        guard let vertices = device.makeBuffer(
            bytes: geometry.vertices, length: geometry.vertices.count * MemoryLayout<Float>.size
        ), let indices = device.makeBuffer(
            bytes: geometry.indices, length: geometry.indices.count * MemoryLayout<UInt32>.size
        ) else { return nil }
        return LeafMesh(
            width: width, height: height, step: step, vertices: vertices, indices: indices,
            indexCount: geometry.indices.count
        )
    }

    func fits(width: Float, height: Float, step: Float) -> Bool {
        self.width == width && self.height == height && self.step == step
    }
}

/// The shadow's levels for one screen size.
final class CurlShadowTextures: @unchecked Sendable {
    static let format: MTLPixelFormat = .rg16Float

    /// Level 0 is the sharp outline, the others as `CurlShadowLevels` lays them out.
    let levels: [MTLTexture]
    /// Every level after the outline is blurred one way into here, then the other way into itself.
    let halfway: [MTLTexture]

    private init(levels: [MTLTexture], halfway: [MTLTexture]) {
        self.levels = levels
        self.halfway = halfway
    }

    static func outlineSize(screenPoints: CGSize) -> (width: Int, height: Int) {
        let texel = CGFloat(CurlShadowLevels.texelPoints)
        return (
            max(1, Int((screenPoints.width / texel).rounded(.up))),
            max(1, Int((screenPoints.height / texel).rounded(.up)))
        )
    }

    static func make(device: MTLDevice, screenPoints: CGSize, count: Int) -> CurlShadowTextures? {
        let (width, height) = outlineSize(screenPoints: screenPoints)
        func texture(_ w: Int, _ h: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: max(1, w), height: max(1, h), mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }
        var levels: [MTLTexture] = []
        var halfway: [MTLTexture] = []
        for level in 0..<count {
            let shrink = CurlShadowLevels.shrink(level)
            guard let made = texture(width / shrink, height / shrink),
                  let between = level == 0 ? made : texture(width / shrink, height / shrink)
            else { return nil }
            levels.append(made)
            halfway.append(between)
        }
        return CurlShadowTextures(levels: levels, halfway: halfway)
    }

    func fits(screenPoints: CGSize, count: Int) -> Bool {
        let size = Self.outlineSize(screenPoints: screenPoints)
        return levels.count >= count && levels[0].width == size.width && levels[0].height == size.height
    }
}

/// The multisample color and depth targets of one drawable size.
final class CurlRenderTargets: @unchecked Sendable {
    let color: MTLTexture
    let depth: MTLTexture

    private init(color: MTLTexture, depth: MTLTexture) {
        self.color = color
        self.depth = depth
    }

    static func make(
        device: MTLDevice, width: Int, height: Int,
        colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat, sampleCount: Int,
        storage: MTLStorageMode
    ) -> CurlRenderTargets? {
        func target(_ format: MTLPixelFormat) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false
            )
            descriptor.textureType = .type2DMultisample
            descriptor.sampleCount = sampleCount
            descriptor.usage = .renderTarget
            descriptor.storageMode = storage
            return device.makeTexture(descriptor: descriptor)
        }
        guard let color = target(colorFormat), let depth = target(depthFormat) else { return nil }
        return CurlRenderTargets(color: color, depth: depth)
    }

    func fits(width: Int, height: Int) -> Bool {
        color.width == width && color.height == height
    }
}
