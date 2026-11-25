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

    let commandQueue: MTLCommandQueue
    private let leafPipeline: MTLRenderPipelineState
    private let backgroundPipeline: MTLRenderPipelineState
    private let shadowPasses: CurlShadowPasses
    private let depthState: MTLDepthStencilState
    private let quadBuffers: [BackgroundQuad: MTLBuffer]
    private let renderTargetStorage: MTLStorageMode

    // The snapshots of the turn being played, held by the view itself from `prepare` until `stop`.
    private var currentTexture: MTLTexture?
    private var targetTexture: MTLTexture?
    /// Whether each snapshot's spread has the spine band; the curl follows the host there.
    private var spineBand = (current: false, target: false)
    private var leafMesh: LeafMesh?
    private var outlineMesh: LeafMesh?
    /// Grids and targets made ahead, off the main thread, for the size `prepareAhead` was given.
    private var meshes: [LeafMesh] = []
    private var targets: CurlRenderTargets?
    private var aheadKey: AheadKey?

    private var trajectory: CurlTrajectory?
    private var scene: CurlScene?
    private var duration: CFTimeInterval = 0
    private var framesPerSecond = 0
    private var startTime: CFTimeInterval = 0
    /// When the frame being drawn reaches the screen.
    private var frameTime: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private var framesDrawn = 0
    private var afterFrames: [(count: Int, action: @MainActor () -> Void)] = []
    private var finished = true
    /// Why the last frame was not drawn; nil when it was.
    private var frameFailure: String?

    private struct AheadKey: Equatable {
        let size: CGSize
        let scale: CGFloat
        let shadowLevels: Int
    }

    // The pipelines and the render targets must agree on these, otherwise Metal rejects the pass.
    private static let msaaSampleCount = 4
    private static let colorFormat = SnapshotRaster.pixelFormat
    private static let depthFormat: MTLPixelFormat = .depth32Float

    /// Built once per device: compiling shaders on every curl drops the first frames.
    private static var pipelineCache: (deviceID: ObjectIdentifier, pipelines: Pipelines)?

    private struct Pipelines {
        let queue: MTLCommandQueue
        let leaf: MTLRenderPipelineState
        let background: MTLRenderPipelineState
        let depth: MTLDepthStencilState
        let shadow: CurlShadowPasses.Pipelines
    }

    public static func warmUp(device: MTLDevice) {
        _ = try? Self.pipelines(device: device)
    }

    /// Why the curl view could not be set up.
    struct SetupFailure: Error {
        let reason: String
    }

    private static func pipelines(device: MTLDevice) throws(SetupFailure) -> Pipelines {
        if let cached = pipelineCache, cached.deviceID == ObjectIdentifier(device) {
            return cached.pipelines
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
        let made = Pipelines(
            queue: queue, leaf: leaf, background: background, depth: depth,
            shadow: try CurlShadowPasses.makePipelines(device: device, function: function)
        )
        pipelineCache = (ObjectIdentifier(device), made)
        return made
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
        let shared: Pipelines
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
        shadowPasses = CurlShadowPasses(pipelines: shared.shadow)

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
        return Self.loadTexture(snapshot, device: device, queue: commandQueue)
    }

    func loadInBackground(_ snapshot: UIImage, completion: @escaping @MainActor (LoadedSnapshot?) -> Void) {
        guard let device else { return completion(nil) }
        let work = MetalHandle(object: (snapshot, device, commandQueue))
        Task.detached(priority: .utility) {
            let (snapshot, device, queue) = work.object
            let loaded = MetalHandle(object: Self.loadTexture(snapshot, device: device, queue: queue))
            await MainActor.run { completion(loaded.object) }
        }
    }

    /// Copies the pixels into a texture and has the GPU make its smaller copies; frames on the same
    /// queue read the texture only after that.
    private nonisolated static func loadTexture(
        _ snapshot: UIImage, device: MTLDevice, queue: MTLCommandQueue
    ) -> SnapshotTexture? {
        do throws(SnapshotLoadFailure) {
            let texture = try makeTexture(from: snapshot, device: device)
            guard let commandBuffer = queue.makeCommandBuffer(),
                  let blit = commandBuffer.makeBlitCommandEncoder()
            else { throw SnapshotLoadFailure.smallerCopiesNotMade }
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commandBuffer.commit()
            return SnapshotTexture(texture: texture)
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
        guard device != nil, sizePoints.width > 0, sizePoints.height > 0 else { return false }
        guard let current = (request.currentSpread as? SnapshotTexture)?.texture,
              let target = (request.targetSpread as? SnapshotTexture)?.texture
        else {
            curlLog.error("overlay not prepared: the snapshots were not loaded by a curl view")
            assertionFailure("The snapshots of a turn must come from load(_:) of a curl view")
            return false
        }

        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
        request.paperColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let trajectory = CurlTrajectory(
            sizePoints: sizePoints, isSpread: request.isSpread, forward: request.forward,
            paper: (Float(red), Float(green), Float(blue)), configuration: configuration
        )
        guard let leaf = mesh(
            width: trajectory.sheetWidth, height: trajectory.sheetHeight, step: LeafMeshGeometry.leafStep
        ), let outline = mesh(
            width: trajectory.sheetWidth, height: trajectory.sheetHeight, step: LeafMeshGeometry.shadowStep
        ) else {
            curlLog.error("overlay not prepared: the leaf mesh was not allocated")
            return false
        }

        // Assigned only once nothing can fail, so a failed prepare leaves no snapshots in the view.
        currentTexture = current
        spineBand = (request.currentSpread.showsSpineBand, request.targetSpread.showsSpineBand)
        targetTexture = target
        leafMesh = leaf
        outlineMesh = outline
        self.trajectory = trajectory
        scene = CurlScene(isSpread: request.isSpread, forward: request.forward)
        duration = configuration.duration
        framesPerSecond = configuration.preferredFramesPerSecond
        frame = CGRect(origin: .zero, size: sizePoints)
        drawableSize = CGSize(width: current.width, height: current.height)
        return true
    }

    /// Builds the turn's grids, the shadow's textures and the render targets on a background
    /// queue, so a turn of this size finds them ready.
    func prepareAhead(sizePoints: CGSize, scale: CGFloat, configuration: PageCurlConfiguration) {
        guard let device, sizePoints.width > 0, sizePoints.height > 0 else { return }
        let levels = CurlShadowLevels.needed(maxWidth: Float(configuration.shadow.maxWidth))
        let key = AheadKey(size: sizePoints, scale: scale, shadowLevels: levels)
        guard key != aheadKey else { return }
        aheadKey = key
        let handle = MetalHandle(object: device)
        let storage = renderTargetStorage
        let formats = (color: Self.colorFormat, depth: Self.depthFormat, samples: Self.msaaSampleCount)
        Task.detached(priority: .utility) { [weak self] in
            let device = handle.object
            let width = Float(sizePoints.width)
            let height = Float(sizePoints.height)
            var meshes: [LeafMesh] = []
            for sheetWidth in [width / 2, width] {
                for step in [LeafMeshGeometry.leafStep, LeafMeshGeometry.shadowStep] {
                    if let mesh = LeafMesh.make(device: device, width: sheetWidth, height: height, step: step) {
                        meshes.append(mesh)
                    }
                }
            }
            let shadow = CurlShadowTextures.make(device: device, screenPoints: sizePoints, count: levels)
            let targets = CurlRenderTargets.make(
                device: device,
                width: Int((sizePoints.width * scale).rounded()),
                height: Int((sizePoints.height * scale).rounded()),
                colorFormat: formats.color, depthFormat: formats.depth,
                sampleCount: formats.samples, storage: storage
            )
            let made = MetalHandle(object: (meshes, shadow, targets))
            await MainActor.run {
                guard let self, self.aheadKey == key else { return }
                let (meshes, shadow, targets) = made.object
                self.meshes = meshes
                if let shadow { self.shadowPasses.adopt(shadow) }
                if let targets { self.targets = targets }
            }
        }
    }

    /// The grid made ahead for this sheet, or one made now.
    private func mesh(width: Float, height: Float, step: Float) -> LeafMesh? {
        if let ready = meshes.first(where: { $0.fits(width: width, height: height, step: step) }) {
            return ready
        }
        guard let device else { return nil }
        curlLog.notice("leaf grid made during a turn")
        let made = LeafMesh.make(device: device, width: width, height: height, step: step)
        if let made { meshes.append(made) }
        return made
    }

    /// A new texture with the snapshot's pixels. It is never written again, so a frame still on the
    /// GPU can read it while the next turn is prepared.
    nonisolated static func makeTexture(
        from image: UIImage, device: MTLDevice
    ) throws(SnapshotLoadFailure) -> MTLTexture {
        let raster = try SnapshotRaster(image)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: SnapshotRaster.pixelFormat, width: raster.width, height: raster.height,
            mipmapped: true
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
        frameTime = startTime
        framesDrawn = 0
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
            curlLog.error("first frame not drawn: \(frameFailure, privacy: .public)")
            return false
        }
        guard !finished else { return true }
        let rate = Float(framesPerSecond > 0
            ? framesPerSecond
            : (window?.screen.maximumFramesPerSecond ?? 60))
        // Each frame is drawn for the moment it reaches the screen.
        let link = CADisplayLink(target: FrameTicker(self), selector: #selector(FrameTicker.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        displayLink = link
        return true
    }

    fileprivate func tick(_ link: CADisplayLink) {
        frameTime = link.targetTimestamp
        draw()
    }

    private func stopTicking() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func afterFramesShown(_ count: Int, _ action: @escaping @MainActor () -> Void) {
        guard !finished, framesDrawn < count else { return action() }
        afterFrames.append((count, action))
    }

    private func runAfterFrames(all: Bool) {
        let due = afterFrames.filter { all || $0.count <= framesDrawn }
        afterFrames.removeAll { all || $0.count <= framesDrawn }
        due.forEach { $0.action() }
    }

    func stop() {
        stopTicking()
        runAfterFrames(all: true)
        finished = true
        onFinished = nil
        // A submitted frame keeps its own references to the textures it reads.
        currentTexture = nil
        targetTexture = nil
    }

    func releaseRenderTargets() {
        targets = nil
        aheadKey = nil
        shadowPasses.release()
    }

    /// The multisample color and depth targets for the drawable's size: made ahead, or now when the
    /// size is new.
    private func renderTargets(width: Int, height: Int) -> CurlRenderTargets? {
        if let targets, targets.fits(width: width, height: height) { return targets }
        guard let device else { return nil }
        curlLog.notice("render targets made during a turn: \(width)x\(height)")
        targets = CurlRenderTargets.make(
            device: device, width: width, height: height,
            colorFormat: Self.colorFormat, depthFormat: Self.depthFormat,
            sampleCount: Self.msaaSampleCount, storage: renderTargetStorage
        )
        return targets
    }
}

extension PageCurlOverlayView: MTKViewDelegate {

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        let elapsed = frameTime - startTime
        let progress = Float(min(max(elapsed / duration, 0), 1))
        frameFailure = renderFrame(progress: progress)
        guard frameFailure == nil else { return }
        framesDrawn += 1
        runAfterFrames(all: false)

        if progress >= 1, !finished {
            finished = true
            stopTicking()
            runAfterFrames(all: true)
            curlLog.debug("curl finished")
            onFinished?()
        }
    }

    /// Encodes and presents one frame; returns why it was not drawn, or nil.
    private func renderFrame(progress: Float) -> String? {
        guard let trajectory, let scene, let currentTexture, let targetTexture, let leafMesh,
              let outlineMesh
        else {
            return "nothing prepared"
        }
        guard let drawable = currentDrawable else { return "no drawable" }
        guard let targets = renderTargets(
            width: drawable.texture.width, height: drawable.texture.height
        ) else { return "render targets not allocated" }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return "no command buffer" }

        var uniforms = trajectory.uniforms(atProgress: scene.trajectoryProgress(progress))
        if uniforms.shadowStrength > 0, !shadowPasses.encode(
            into: commandBuffer, uniforms: &uniforms, outlineMesh: outlineMesh
        ) {
            uniforms.shadowStrength = 0
        }

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
        func band(_ snapshot: CurlSnapshot) -> Float {
            (snapshot == .current ? spineBand.current : spineBand.target) ? 1 : 0
        }

        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        // Without this the leaf shows its back at t=0.
        encoder.setFrontFacing(scene.frontFacesCounterClockwise ? .counterClockwise : .clockwise)

        var gutter = trajectory.lightTable
        let gutterLength = gutter.count * MemoryLayout<Float>.stride
        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CurlUniforms>.size, index: 1)
        encoder.setFragmentBytes(&gutter, length: gutterLength, index: 2)
        // Without a shadow the shader reads none of these, but every slot must be bound.
        let shadowLevels = uniforms.shadowStrength > 0
            ? shadowPasses.levels
            : Array(repeating: currentTexture, count: CurlShadowLevels.count)
        encoder.setFragmentTextures(shadowLevels, range: 1..<(1 + CurlShadowLevels.count))
        for background in scene.backgrounds {
            encoder.setVertexBuffer(quadBuffers[background.quad], offset: 0, index: 0)
            encoder.setFragmentTexture(texture(background.snapshot), index: 0)
            var hasBand = band(background.snapshot)
            encoder.setFragmentBytes(&hasBand, length: MemoryLayout<Float>.size, index: 3)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        encoder.setRenderPipelineState(leafPipeline)
        encoder.setVertexBuffer(leafMesh.vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CurlUniforms>.size, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CurlUniforms>.size, index: 1)
        encoder.setFragmentBytes(&gutter, length: gutterLength, index: 2)
        var leafBands = SIMD2<Float>(band(scene.leafFace), band(scene.leafBack))
        encoder.setFragmentBytes(&leafBands, length: MemoryLayout<SIMD2<Float>>.size, index: 3)
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

/// The display link holds its target strongly; this keeps the curl view out of that.
@MainActor
private final class FrameTicker: NSObject {
    private weak var view: PageCurlOverlayView?

    init(_ view: PageCurlOverlayView) {
        self.view = view
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let view else {
            link.invalidate()
            return
        }
        view.tick(link)
    }
}

/// The curl view's form of a loaded snapshot.
final class SnapshotTexture: LoadedSnapshot {
    let texture: MTLTexture
    var showsSpineBand = false

    init(texture: MTLTexture) {
        self.texture = texture
    }
}
