import UIKit
import MetalKit

/// The curl effect itself: takes two snapshots, runs the animation to the end on its own and
/// calls `onFinished`. Does not receive touches.
///
/// `PageCurlController` creates and manages this view; use it directly only if you drive the
/// transition yourself.
@MainActor
public final class PageCurlOverlayView: MTKView, PageCurlOverlayAnimating {

    /// Called when the animation completes. To cancel, remove the view from its superview; this is
    /// then not called.
    public var onFinished: (() -> Void)?

    private let commandQueue: MTLCommandQueue
    private let leafPipeline: MTLRenderPipelineState
    private let backgroundPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let leftQuadBuffer: MTLBuffer
    private let rightQuadBuffer: MTLBuffer
    private let fullQuadBuffer: MTLBuffer
    private let renderTargetStorage: MTLStorageMode

    // Refilled by `prepare` for every turn; allocated again only when the size changes.
    private var currentTexture: MTLTexture?
    private var targetTexture: MTLTexture?
    private var leafMesh: LeafMesh?
    // Follow the drawable size; allocated again only when it changes.
    private var multisampleTexture: MTLTexture?
    private var depthTexture: MTLTexture?

    private var trajectory: CurlTrajectory?
    private var duration: CFTimeInterval = 0
    private var isSpread = false
    private var forward = true
    private var framesPerSecond = 0
    private var startTime: CFTimeInterval = 0
    private var finished = true
    /// The last submitted frame; the snapshot textures are not overwritten while it may still read them.
    private var lastCommandBuffer: MTLCommandBuffer?
    /// Why the last frame was not drawn; nil when it was.
    private var frameFailure: String?

    private struct LeafMesh {
        let width: Float
        let height: Float
        let vertices: MTLBuffer
        let indices: MTLBuffer
        let indexCount: Int
    }

    // The pipelines and the render targets must agree on these, otherwise Metal rejects the pass.
    private static let msaaSampleCount = 4
    private static let colorFormat: MTLPixelFormat = .bgra8Unorm
    private static let depthFormat: MTLPixelFormat = .depth32Float

    /// Built once per device: compiling shaders on every curl drops the first frames.
    private static var pipelineCache: (
        deviceID: ObjectIdentifier,
        queue: MTLCommandQueue,
        leaf: MTLRenderPipelineState,
        background: MTLRenderPipelineState,
        depth: MTLDepthStencilState
    )?

    public static func warmUp(device: MTLDevice) {
        _ = Self.pipelines(device: device)
    }

    private static func pipelines(device: MTLDevice) -> (
        queue: MTLCommandQueue,
        leaf: MTLRenderPipelineState,
        background: MTLRenderPipelineState,
        depth: MTLDepthStencilState
    )? {
        if let cached = pipelineCache, cached.deviceID == ObjectIdentifier(device) {
            return (cached.queue, cached.leaf, cached.background, cached.depth)
        }
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: pageCurlShaderSource, options: nil),
              let leafVertex = library.makeFunction(name: "leaf_vertex"),
              let leafFragment = library.makeFunction(name: "leaf_fragment"),
              let bgVertex = library.makeFunction(name: "background_vertex"),
              let bgFragment = library.makeFunction(name: "background_fragment")
        else { return nil }

        func pipeline(_ vertex: MTLFunction, _ fragment: MTLFunction) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            // Not an sRGB format, so snapshot pixels are written as is, without re-encoding.
            descriptor.colorAttachments[0].pixelFormat = colorFormat
            descriptor.depthAttachmentPixelFormat = depthFormat
            descriptor.rasterSampleCount = msaaSampleCount
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .greaterEqual
        depthDescriptor.isDepthWriteEnabled = true
        guard let leaf = pipeline(leafVertex, leafFragment),
              let background = pipeline(bgVertex, bgFragment),
              let depth = device.makeDepthStencilState(descriptor: depthDescriptor)
        else { return nil }
        pipelineCache = (ObjectIdentifier(device), queue, leaf, background, depth)
        return (queue, leaf, background, depth)
    }

    /// The multisample and depth targets live only inside one render pass, so on Apple GPUs they
    /// take no memory. The simulator does not support memoryless textures.
    private static func renderTargetStorage(device: MTLDevice) -> MTLStorageMode {
        #if targetEnvironment(simulator)
        return .private
        #else
        return device.supportsFamily(.apple1) ? .memoryless : .private
        #endif
    }

    /// An empty view for repeated turns: `prepare` loads each turn, `startIfFirstFrameDrawn` runs it.
    init?(device: MTLDevice) {
        guard let shared = Self.pipelines(device: device) else { return nil }
        commandQueue = shared.queue
        leafPipeline = shared.leaf
        backgroundPipeline = shared.background
        depthState = shared.depth

        // Background quads in NDC as (x, y, u, v); v=0 is the top of the snapshot.
        func quad(x0: Float, x1: Float, u0: Float, u1: Float) -> [Float] {
            [
                x0, -1, u0, 1, x0, 1, u0, 0, x1, -1, u1, 1,
                x1, -1, u1, 1, x0, 1, u0, 0, x1, 1, u1, 0,
            ]
        }
        let leftQuad = quad(x0: -1, x1: 0, u0: 0, u1: 0.5)
        let rightQuad = quad(x0: 0, x1: 1, u0: 0.5, u1: 1)
        let fullQuad = quad(x0: -1, x1: 1, u0: 0, u1: 1)
        guard let leftBuffer = device.makeBuffer(
            bytes: leftQuad, length: leftQuad.count * MemoryLayout<Float>.size
        ), let rightBuffer = device.makeBuffer(
            bytes: rightQuad, length: rightQuad.count * MemoryLayout<Float>.size
        ), let fullBuffer = device.makeBuffer(
            bytes: fullQuad, length: fullQuad.count * MemoryLayout<Float>.size
        ) else { return nil }
        leftQuadBuffer = leftBuffer
        rightQuadBuffer = rightBuffer
        fullQuadBuffer = fullBuffer
        renderTargetStorage = Self.renderTargetStorage(device: device)

        super.init(frame: .zero, device: device)
        colorPixelFormat = Self.colorFormat
        // The view owns only the drawable; the multisample and depth targets are ours.
        depthStencilPixelFormat = .invalid
        sampleCount = 1
        // `prepare` sets the drawable size to the snapshots' pixel size before the first frame.
        autoResizeDrawable = false
        isOpaque = true
        isUserInteractionEnabled = false
        isPaused = true
        enableSetNeedsDisplay = false
        delegate = self
    }

    public convenience init?(
        device: MTLDevice,
        currentSpread: UIImage,
        targetSpread: UIImage,
        sizePoints: CGSize,
        forward: Bool,
        isSpread: Bool,
        paperColor: UIColor,
        configuration: PageCurlConfiguration = PageCurlConfiguration()
    ) {
        self.init(device: device)
        guard prepare(PageCurlOverlayRequest(
            currentSpread: currentSpread, targetSpread: targetSpread, sizePoints: sizePoints,
            forward: forward, isSpread: isSpread, paperColor: paperColor,
            configuration: configuration
        )) else { return nil }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Loads one turn into the view, reusing the textures and the mesh when the size is unchanged.
    func prepare(_ request: PageCurlOverlayRequest) -> Bool {
        let sizePoints = request.sizePoints
        let isSpread = request.isSpread
        let forward = request.forward
        let configuration = request.configuration
        guard let device, sizePoints.width > 0, sizePoints.height > 0 else { return false }
        lastCommandBuffer?.waitUntilCompleted()
        lastCommandBuffer = nil

        guard let current = Self.loadSnapshot(
                  request.currentSpread, reusing: currentTexture, device: device
              ),
              let target = Self.loadSnapshot(
                  request.targetSpread, reusing: targetTexture, device: device
              )
        else {
            curlLog.debug("overlay not prepared: a snapshot did not load into a texture")
            return false
        }
        currentTexture = current
        targetTexture = target

        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
        request.paperColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let trajectory = CurlTrajectory(
            sheetWidth: isSpread ? Float(sizePoints.width / 2) : Float(sizePoints.width),
            sheetHeight: Float(sizePoints.height),
            screenHalfWidth: Float(sizePoints.width / 2),
            isSpread: isSpread,
            direction: (isSpread && !forward) ? -1 : 1,
            paper: (Float(red), Float(green), Float(blue)),
            startRadiusFraction: Float(
                isSpread
                    ? configuration.spreadStartRadiusFraction
                    : configuration.singleStartRadiusFraction
            ),
            coneStrength: Float(configuration.coneStrength),
            shadowStrength: Float(configuration.shadowStrength),
            backMirrorOpacity: Float(configuration.backMirrorOpacity)
        )
        if leafMesh?.width != trajectory.sheetWidth || leafMesh?.height != trajectory.sheetHeight {
            leafMesh = nil
            guard let mesh = Self.makeLeafMesh(
                device: device, width: trajectory.sheetWidth, height: trajectory.sheetHeight
            ) else {
                curlLog.debug("overlay not prepared: the leaf mesh was not allocated")
                return false
            }
            leafMesh = mesh
        }

        self.trajectory = trajectory
        self.forward = forward
        self.isSpread = isSpread
        duration = configuration.duration
        framesPerSecond = configuration.preferredFramesPerSecond
        frame = CGRect(origin: .zero, size: sizePoints)
        drawableSize = CGSize(width: current.width, height: current.height)
        return true
    }

    /// About 5 pt between columns, across the fold where the sheet bends; rows can be coarse.
    private static func makeLeafMesh(device: MTLDevice, width: Float, height: Float) -> LeafMesh? {
        let columns = max(2, Int(width / 5))
        let rows = 24
        var vertices: [Float] = []
        vertices.reserveCapacity((columns + 1) * (rows + 1) * 4)
        for row in 0...rows {
            let v = Float(row) / Float(rows)
            for column in 0...columns {
                let u = Float(column) / Float(columns)
                vertices.append(contentsOf: [u * width, v * height, u, v])
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(columns * rows * 6)
        let stride = UInt32(columns + 1)
        for row in 0..<UInt32(rows) {
            for column in 0..<UInt32(columns) {
                let a = row * stride + column
                let b = a + 1
                let c = a + stride
                let d = c + 1
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        guard let vertexBuffer = device.makeBuffer(
            bytes: vertices, length: vertices.count * MemoryLayout<Float>.size
        ), let indexBuffer = device.makeBuffer(
            bytes: indices, length: indices.count * MemoryLayout<UInt32>.size
        ) else { return nil }
        return LeafMesh(
            width: width, height: height,
            vertices: vertexBuffer, indices: indexBuffer, indexCount: indices.count
        )
    }

    /// Writes the snapshot's pixels into `reusing` when it has the same size, otherwise into a new
    /// texture. The bytes are copied as is: 8-bit BGRA, no sRGB re-encoding.
    static func loadSnapshot(_ image: UIImage, reusing: MTLTexture?, device: MTLDevice) -> MTLTexture? {
        guard let source = image.cgImage,
              let raster = isPipelineRaster(source) ? source : normalizedRaster(source),
              let data = raster.dataProvider?.data,
              CFDataGetLength(data) >= raster.bytesPerRow * raster.height,
              let bytes = CFDataGetBytePtr(data)
        else { return nil }
        let texture: MTLTexture
        if let reusing, reusing.width == raster.width, reusing.height == raster.height {
            texture = reusing
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: colorFormat, width: raster.width, height: raster.height,
                mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            guard let made = device.makeTexture(descriptor: descriptor) else { return nil }
            texture = made
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, raster.width, raster.height),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: raster.bytesPerRow
        )
        return texture
    }

    /// Whether the bytes already are what the pipeline reads: 8-bit BGRA with alpha first.
    nonisolated static func isPipelineRaster(_ cgImage: CGImage) -> Bool {
        let alpha = cgImage.alphaInfo
        return cgImage.bitsPerComponent == 8
            && cgImage.bitsPerPixel == 32
            && cgImage.byteOrderInfo == .order32Little
            && (alpha == .premultipliedFirst || alpha == .noneSkipFirst)
    }

    /// Redraw into the pipeline's raster: 8-bit BGRA, sRGB.
    nonisolated static func normalizedRaster(_ cgImage: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: cgImage.width,
                  height: cgImage.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return context.makeImage()
    }

    /// Starts the animation. If the first frame cannot be drawn, nothing runs and `onFinished` is
    /// called at once, so the caller removes the view and shows the target instantly.
    public func start() {
        if !startIfFirstFrameDrawn() {
            onFinished?()
        }
    }

    /// Draws the first frame and starts the animation; false — the first frame did not reach the
    /// screen and the animation did not start.
    func startIfFirstFrameDrawn() -> Bool {
        guard trajectory != nil else {
            curlLog.debug("first frame not drawn: nothing prepared")
            return false
        }
        finished = false
        startTime = CACurrentMediaTime()
        frameFailure = "the view did not ask for a frame"
        // The first frame (an exact copy of the current spread) is drawn synchronously and presented
        // within the current Core Animation transaction. Metal presents asynchronously, so otherwise
        // the host's swap of the spread under the overlay reaches the screen before the first frame,
        // and the target page flashes.
        (layer as? CAMetalLayer)?.presentsWithTransaction = true
        draw()
        (layer as? CAMetalLayer)?.presentsWithTransaction = false
        if let frameFailure {
            finished = true
            isPaused = true
            curlLog.debug("first frame not drawn: \(frameFailure, privacy: .public)")
            return false
        }
        guard !finished else { return true }
        isPaused = false
        preferredFramesPerSecond = framesPerSecond > 0
            ? framesPerSecond
            : (window?.screen.maximumFramesPerSecond ?? 60)
        return true
    }

    func stop() {
        isPaused = true
        finished = true
        onFinished = nil
    }

    func releaseTextures() {
        lastCommandBuffer = nil
        currentTexture = nil
        targetTexture = nil
        multisampleTexture = nil
        depthTexture = nil
    }

    /// The multisample color and depth targets for the drawable's size, allocated again only when
    /// that size changes.
    private func renderTargets(width: Int, height: Int) -> (color: MTLTexture, depth: MTLTexture)? {
        if let color = multisampleTexture, let depth = depthTexture,
           color.width == width, color.height == height {
            return (color, depth)
        }
        multisampleTexture = nil
        depthTexture = nil
        guard let device,
              let color = makeRenderTarget(device: device, format: Self.colorFormat, width: width, height: height),
              let depth = makeRenderTarget(device: device, format: Self.depthFormat, width: width, height: height)
        else { return nil }
        multisampleTexture = color
        depthTexture = depth
        curlLog.debug(
            "render targets \(width)x\(height), memoryless: \(self.renderTargetStorage == .memoryless)"
        )
        return (color, depth)
    }

    private func makeRenderTarget(
        device: MTLDevice, format: MTLPixelFormat, width: Int, height: Int
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
        )
        descriptor.textureType = .type2DMultisample
        descriptor.sampleCount = Self.msaaSampleCount
        descriptor.usage = .renderTarget
        descriptor.storageMode = renderTargetStorage
        return device.makeTexture(descriptor: descriptor)
    }
}

extension PageCurlOverlayView: MTKViewDelegate {

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        let elapsed = CACurrentMediaTime() - startTime
        let progress = Float(min(max(elapsed / duration, 0), 1))
        frameFailure = renderFrame(progress: progress)
        guard frameFailure == nil else { return }

        if progress >= 1, !finished {
            finished = true
            isPaused = true
            curlLog.debug("curl finished")
            onFinished?()
        }
    }

    /// Encodes and presents one frame; returns why it was not drawn, or nil.
    private func renderFrame(progress: Float) -> String? {
        guard let trajectory, let currentTexture, let targetTexture, let leafMesh else {
            return "nothing prepared"
        }
        guard let drawable = currentDrawable else { return "no drawable" }
        guard let targets = renderTargets(
            width: drawable.texture.width, height: drawable.texture.height
        ) else { return "render targets not allocated" }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return "no command buffer" }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = targets.color
        descriptor.colorAttachments[0].resolveTexture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .multisampleResolve
        descriptor.depthAttachment.texture = targets.depth
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.clearDepth = 0
        descriptor.depthAttachment.storeAction = .dontCare
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return "no render encoder"
        }

        // Single-page backward: the forward trajectory with time reversed.
        let trajectoryProgress = (isSpread || forward) ? progress : 1 - progress

        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        // The flat mesh is wound counter-clockwise; the mirrored direction flips the winding.
        // Without this the leaf shows its back at t=0.
        encoder.setFrontFacing(trajectory.direction > 0 ? .counterClockwise : .clockwise)

        var uniforms = trajectory.uniforms(atProgress: trajectoryProgress)

        // Spread: the half that stays comes from the current snapshot, the half being revealed from
        // the target. Single page: the page underneath is the target going forward and the current
        // page going backward.
        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CurlUniforms>.size, index: 1)
        if isSpread {
            encoder.setVertexBuffer(leftQuadBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(forward ? currentTexture : targetTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.setVertexBuffer(rightQuadBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(forward ? targetTexture : currentTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        } else {
            encoder.setVertexBuffer(fullQuadBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(forward ? targetTexture : currentTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        // Single page backward: the target page curls back in, so it is the leaf.
        let leafTexture = (isSpread || forward) ? currentTexture : targetTexture
        encoder.setRenderPipelineState(leafPipeline)
        encoder.setVertexBuffer(leafMesh.vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CurlUniforms>.size, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CurlUniforms>.size, index: 1)
        encoder.setFragmentTexture(leafTexture, index: 0)
        encoder.setFragmentTexture(targetTexture, index: 1)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: leafMesh.indexCount,
            indexType: .uint32,
            indexBuffer: leafMesh.indices,
            indexBufferOffset: 0
        )

        encoder.endEncoding()
        // First frame: wait until scheduled and present directly so it lands in the current Core
        // Animation transaction.
        if (layer as? CAMetalLayer)?.presentsWithTransaction == true {
            commandBuffer.commit()
            commandBuffer.waitUntilScheduled()
            drawable.present()
        } else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
        lastCommandBuffer = commandBuffer
        return nil
    }
}
