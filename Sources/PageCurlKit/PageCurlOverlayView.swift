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
    private let quadBuffers: [BackgroundQuad: MTLBuffer]
    private let renderTargetStorage: MTLStorageMode

    // The snapshots of the turn being played, held by the view itself from `prepare` until `stop`.
    private var currentTexture: MTLTexture?
    private var targetTexture: MTLTexture?
    private var leafMesh: LeafMesh?
    // Follow the drawable size; allocated again only when it changes.
    private var multisampleTexture: MTLTexture?
    private var depthTexture: MTLTexture?

    private var trajectory: CurlTrajectory?
    private var scene: CurlScene?
    private var duration: CFTimeInterval = 0
    private var framesPerSecond = 0
    private var startTime: CFTimeInterval = 0
    private var finished = true
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
    private static let colorFormat = SnapshotRaster.pixelFormat
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
        _ = try? Self.pipelines(device: device)
    }

    /// Why the curl view could not be set up.
    struct SetupFailure: Error {
        let reason: String
    }

    private static func pipelines(device: MTLDevice) throws(SetupFailure) -> (
        queue: MTLCommandQueue,
        leaf: MTLRenderPipelineState,
        background: MTLRenderPipelineState,
        depth: MTLDepthStencilState
    ) {
        if let cached = pipelineCache, cached.deviceID == ObjectIdentifier(device) {
            return (cached.queue, cached.leaf, cached.background, cached.depth)
        }
        guard let queue = device.makeCommandQueue() else {
            throw SetupFailure(reason: "no command queue")
        }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: pageCurlShaderSource, options: nil)
        } catch {
            throw SetupFailure(reason: "shaders did not compile: \(error.localizedDescription)")
        }
        func function(_ name: String) throws(SetupFailure) -> MTLFunction {
            guard let function = library.makeFunction(name: name) else {
                throw SetupFailure(reason: "no shader function \(name)")
            }
            return function
        }
        func pipeline(_ vertex: String, _ fragment: String) throws(SetupFailure) -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = try function(vertex)
            descriptor.fragmentFunction = try function(fragment)
            // Not an sRGB format, so snapshot pixels are written as is, without re-encoding.
            descriptor.colorAttachments[0].pixelFormat = colorFormat
            descriptor.depthAttachmentPixelFormat = depthFormat
            descriptor.rasterSampleCount = msaaSampleCount
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                throw SetupFailure(reason: "pipeline \(vertex) not built: \(error.localizedDescription)")
            }
        }
        let leaf = try pipeline("leaf_vertex", "leaf_fragment")
        let background = try pipeline("background_vertex", "background_fragment")
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .greaterEqual
        depthDescriptor.isDepthWriteEnabled = true
        guard let depth = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw SetupFailure(reason: "no depth state")
        }
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

    /// An empty view for repeated turns: `load` takes the snapshots, `prepare` takes each turn,
    /// `startIfFirstFrameDrawn` runs it.
    init?(device: MTLDevice) {
        let shared: (
            queue: MTLCommandQueue,
            leaf: MTLRenderPipelineState,
            background: MTLRenderPipelineState,
            depth: MTLDepthStencilState
        )
        do {
            shared = try Self.pipelines(device: device)
        } catch {
            curlLog.error("curl view not made: \(error.reason, privacy: .public)")
            return nil
        }
        commandQueue = shared.queue
        leafPipeline = shared.leaf
        backgroundPipeline = shared.background
        depthState = shared.depth

        var quadBuffers: [BackgroundQuad: MTLBuffer] = [:]
        for quad in BackgroundQuad.allCases {
            let vertices = quad.vertices
            guard let buffer = device.makeBuffer(
                bytes: vertices, length: vertices.count * MemoryLayout<Float>.size
            ) else {
                curlLog.error("curl view not made: no buffer for the background")
                return nil
            }
            quadBuffers[quad] = buffer
        }
        self.quadBuffers = quadBuffers
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
        guard let current = load(currentSpread), let target = load(targetSpread) else { return nil }
        guard prepare(PageCurlOverlayRequest(
            currentSpread: current, targetSpread: target, sizePoints: sizePoints,
            forward: forward, isSpread: isSpread, paperColor: paperColor,
            configuration: configuration
        )) else { return nil }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func load(_ snapshot: UIImage) -> LoadedSnapshot? {
        guard let device else { return nil }
        do {
            return SnapshotTexture(texture: try Self.makeTexture(from: snapshot, device: device))
        } catch {
            curlLog.error("snapshot not loaded: \(error.rawValue, privacy: .public)")
            return nil
        }
    }

    /// Takes the loaded snapshots of one turn without copying pixels; reuses the mesh when the size
    /// is unchanged.
    func prepare(_ request: PageCurlOverlayRequest) -> Bool {
        let sizePoints = request.sizePoints
        let configuration = request.configuration
        guard let device, sizePoints.width > 0, sizePoints.height > 0 else { return false }
        guard let current = (request.currentSpread as? SnapshotTexture)?.texture,
              let target = (request.targetSpread as? SnapshotTexture)?.texture
        else {
            curlLog.error("overlay not prepared: the snapshots were not loaded by a curl view")
            return false
        }
        currentTexture = current
        targetTexture = target

        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
        request.paperColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let trajectory = CurlTrajectory(
            sizePoints: sizePoints, isSpread: request.isSpread, forward: request.forward,
            paper: (Float(red), Float(green), Float(blue)), configuration: configuration
        )
        if leafMesh?.width != trajectory.sheetWidth || leafMesh?.height != trajectory.sheetHeight {
            leafMesh = nil
            guard let mesh = Self.makeLeafMesh(
                device: device, width: trajectory.sheetWidth, height: trajectory.sheetHeight
            ) else {
                curlLog.error("overlay not prepared: the leaf mesh was not allocated")
                return false
            }
            leafMesh = mesh
        }

        self.trajectory = trajectory
        scene = CurlScene(isSpread: request.isSpread, forward: request.forward)
        duration = configuration.duration
        framesPerSecond = configuration.preferredFramesPerSecond
        frame = CGRect(origin: .zero, size: sizePoints)
        drawableSize = CGSize(width: current.width, height: current.height)
        return true
    }

    private static func makeLeafMesh(device: MTLDevice, width: Float, height: Float) -> LeafMesh? {
        let geometry = LeafMeshGeometry(width: width, height: height)
        let vertices = geometry.vertices
        let indices = geometry.indices
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

    /// A new texture with the snapshot's pixels. It is never written again, so a frame still on the
    /// GPU can read it while the next turn is prepared.
    static func makeTexture(
        from image: UIImage, device: MTLDevice
    ) throws(SnapshotLoadFailure) -> MTLTexture {
        let raster = try SnapshotRaster(image)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: SnapshotRaster.pixelFormat, width: raster.width, height: raster.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw .textureNotAllocated
        }
        raster.bytes.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, raster.width, raster.height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: raster.bytesPerRow
            )
        }
        return texture
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
        guard scene != nil else {
            curlLog.error("first frame not drawn: nothing prepared")
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
            curlLog.error("first frame not drawn: \(frameFailure, privacy: .public)")
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
        // A submitted frame keeps its own references to the textures it reads.
        currentTexture = nil
        targetTexture = nil
    }

    func releaseRenderTargets() {
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
        curlLog.notice(
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
        guard let trajectory, let scene, let currentTexture, let targetTexture, let leafMesh else {
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

        func texture(_ snapshot: CurlSnapshot) -> MTLTexture {
            snapshot == .current ? currentTexture : targetTexture
        }

        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        // Without this the leaf shows its back at t=0.
        encoder.setFrontFacing(scene.frontFacesCounterClockwise ? .counterClockwise : .clockwise)

        var uniforms = trajectory.uniforms(atProgress: scene.trajectoryProgress(progress))

        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CurlUniforms>.size, index: 1)
        for background in scene.backgrounds {
            encoder.setVertexBuffer(quadBuffers[background.quad], offset: 0, index: 0)
            encoder.setFragmentTexture(texture(background.snapshot), index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        encoder.setRenderPipelineState(leafPipeline)
        encoder.setVertexBuffer(leafMesh.vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CurlUniforms>.size, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CurlUniforms>.size, index: 1)
        encoder.setFragmentTexture(texture(scene.leafFace), index: 0)
        encoder.setFragmentTexture(texture(scene.leafBack), index: 1)
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
        return nil
    }
}

/// The curl view's form of a loaded snapshot.
final class SnapshotTexture: LoadedSnapshot {
    let texture: MTLTexture

    init(texture: MTLTexture) {
        self.texture = texture
    }
}
