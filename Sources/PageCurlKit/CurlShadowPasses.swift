import Metal

/// How the shadow's levels of softness are laid out; the shader is built with these numbers.
enum CurlShadowLevels {
    static let count = 7
    /// Points of the screen per texel of the sharp outline.
    static let texelPoints: Float = 2
    /// Linear filtering reads the sharp outline as a triangle one texel wide each way, which
    /// softens it by this many points.
    static let sharpBlur = texelPoints * (Float(1) / 6).squareRoot()
    /// Level 1 blurs by this many points.
    static let firstBlur: Float = 4
    /// Each level after the first is this many times softer than the one before and its texture
    /// this many times smaller.
    static let growth = 2
    /// The level whose softness is wide enough to average the leaf's height around a place.
    static let averaging = 4

    /// How many levels a soft edge up to `maxWidth` points needs: the averaging one and enough to
    /// reach that softness.
    static func needed(maxWidth: Float) -> Int {
        var top = averaging
        while top + 1 < count, blur(top) < maxWidth / 2 {
            top += 1
        }
        return top + 1
    }

    /// How soft the level is, in points.
    static func blur(_ level: Int) -> Float {
        level == 0 ? sharpBlur : firstBlur * Float(shrink(level))
    }

    /// How many times smaller than the outline the level's texture is.
    static func shrink(_ level: Int) -> Int {
        level <= 1 ? 1 : Int(pow(Float(growth), Float(level - 1)))
    }

    /// The blur that takes the level before to this one, in this level's texels.
    static func added(_ level: Int) -> Float {
        let more = (blur(level) * blur(level) - blur(level - 1) * blur(level - 1)).squareRoot()
        return more / (texelPoints * Float(shrink(level)))
    }
}

/// The leaf's shadow on the page, drawn before each frame: the leaf moved along the lamp's ray onto
/// the page, then blurred into levels of growing softness. The background picks its level by the
/// leaf's height (`shadowAt` in the shader).
@MainActor
final class CurlShadowPasses {
    struct Pipelines {
        let outline: MTLRenderPipelineState
        let blur: MTLRenderPipelineState
    }

    static func makePipelines(
        device: MTLDevice, function: (String) throws(PageCurlOverlayView.SetupFailure) -> MTLFunction
    ) throws(PageCurlOverlayView.SetupFailure) -> Pipelines {
        func pipeline(
            _ vertex: String, _ fragment: String, blendsByMaximum: Bool
        ) throws(PageCurlOverlayView.SetupFailure) -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = try function(vertex)
            descriptor.fragmentFunction = try function(fragment)
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = CurlShadowTextures.format
            if blendsByMaximum {
                // Where the leaf overlaps itself, the outline keeps the highest layer.
                color.isBlendingEnabled = true
                color.rgbBlendOperation = .max
                color.sourceRGBBlendFactor = .one
                color.destinationRGBBlendFactor = .one
            }
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                throw .init(reason: "pipeline \(vertex) not built: \(error.localizedDescription)")
            }
        }
        return Pipelines(
            outline: try pipeline("shadow_vertex", "shadow_fragment", blendsByMaximum: true),
            blur: try pipeline("fullscreen_vertex", "blur_fragment", blendsByMaximum: false)
        )
    }

    private let pipelines: Pipelines
    private var textures: CurlShadowTextures?

    /// What the background reads, one texture per level of the shader, unused ones repeated.
    var levels: [MTLTexture] {
        guard let textures else { return [] }
        return (0..<CurlShadowLevels.count).map { textures.levels[min($0, textures.levels.count - 1)] }
    }

    init(pipelines: Pipelines) {
        self.pipelines = pipelines
    }

    /// Textures made ahead of the turn, off the main thread.
    func adopt(_ textures: CurlShadowTextures) {
        self.textures = textures
    }

    func release() {
        textures = nil
    }

    /// Encodes the outline and the blur; false — there is nothing to bind and the frame goes
    /// without a shadow.
    func encode(
        into commandBuffer: MTLCommandBuffer, uniforms: inout CurlUniforms, outlineMesh: LeafMesh
    ) -> Bool {
        let screen = CGSize(width: CGFloat(uniforms.halfWidth * 2), height: CGFloat(uniforms.height))
        let count = CurlShadowLevels.needed(maxWidth: uniforms.shadowMaxWidth)
        if textures?.fits(screenPoints: screen, count: count) != true {
            // Normally made ahead; a size or width not seen before is made here.
            curlLog.notice("shadow levels made during a turn")
            textures = CurlShadowTextures.make(device: commandBuffer.device, screenPoints: screen, count: count)
        }
        guard let textures else { return false }
        uniforms.shadowTopLevel = Float(count - 1)

        func pass(_ target: MTLTexture) -> MTLRenderCommandEncoder? {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = target
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            descriptor.colorAttachments[0].storeAction = .store
            return commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        }

        guard let outline = pass(textures.levels[0]) else { return false }
        outline.setRenderPipelineState(pipelines.outline)
        outline.setCullMode(.none)
        outline.setVertexBuffer(outlineMesh.vertices, offset: 0, index: 0)
        outline.setVertexBytes(&uniforms, length: MemoryLayout<CurlUniforms>.size, index: 1)
        outline.drawIndexedPrimitives(
            type: .triangle, indexCount: outlineMesh.indexCount, indexType: .uint32,
            indexBuffer: outlineMesh.indices, indexBufferOffset: 0
        )
        outline.endEncoding()

        struct BlurStep {
            var step: SIMD2<Float>
            var sigma: Float
        }
        for level in 1..<count {
            let target = textures.levels[level]
            let sigma = CurlShadowLevels.added(level)
            let steps = [
                (textures.halfway[level], textures.levels[level - 1], SIMD2<Float>(1 / Float(target.width), 0)),
                (target, textures.halfway[level], SIMD2<Float>(0, 1 / Float(target.height))),
            ]
            for (destination, source, step) in steps {
                guard let blur = pass(destination) else { return false }
                var parameters = BlurStep(step: step, sigma: sigma)
                blur.setRenderPipelineState(pipelines.blur)
                blur.setFragmentBytes(&parameters, length: MemoryLayout<BlurStep>.stride, index: 0)
                blur.setFragmentTexture(source, index: 0)
                blur.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                blur.endEncoding()
            }
        }
        return true
    }
}
