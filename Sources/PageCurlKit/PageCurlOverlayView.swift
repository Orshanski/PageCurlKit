import UIKit
import MetalKit

/// The curl effect itself: takes two snapshots, runs the animation to the end on its own and
/// calls `onFinished`. Does not receive touches.
///
/// `PageCurlController` creates and manages this view; use it directly only if you drive the
/// transition yourself.
@MainActor
public final class PageCurlOverlayView: MTKView {

    /// Called when the animation completes. To cancel, remove the view from its superview; this is
    /// then not called.
    public var onFinished: (() -> Void)?

    private let commandQueue: MTLCommandQueue
    private let leafPipeline: MTLRenderPipelineState
    private let backgroundPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let currentTexture: MTLTexture
    private let targetTexture: MTLTexture
    private let leafVertexBuffer: MTLBuffer
    private let leafIndexBuffer: MTLBuffer
    private let leafIndexCount: Int
    private let leftQuadBuffer: MTLBuffer
    private let rightQuadBuffer: MTLBuffer
    private let fullQuadBuffer: MTLBuffer

    private let trajectory: CurlTrajectory
    private let duration: CFTimeInterval
    private let isSpread: Bool
    private let forward: Bool
    private let framesPerSecond: Int
    private var startTime: CFTimeInterval = 0
    private var finished = false

    // The pipelines and the view must agree on these, otherwise Metal rejects the render pass.
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

    public init?(
        device: MTLDevice,
        currentSpread: UIImage,
        targetSpread: UIImage,
        sizePoints: CGSize,
        forward: Bool,
        isSpread: Bool,
        paperColor: UIColor,
        configuration: PageCurlConfiguration = PageCurlConfiguration()
    ) {
        guard sizePoints.width > 0, sizePoints.height > 0,
              let shared = Self.pipelines(device: device)
        else { return nil }
        commandQueue = shared.queue
        leafPipeline = shared.leaf
        backgroundPipeline = shared.background
        depthState = shared.depth
        duration = configuration.duration
        self.isSpread = isSpread
        self.forward = forward
        framesPerSecond = configuration.preferredFramesPerSecond
        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
        paperColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        trajectory = CurlTrajectory(
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

        let loader = MTKTextureLoader(device: device)
        guard let current = Self.texture(from: currentSpread, loader: loader),
              let target = Self.texture(from: targetSpread, loader: loader)
        else { return nil }
        currentTexture = current
        targetTexture = target

        // About 5 pt between columns, across the fold where the sheet bends; rows can be coarse.
        let sheetWidth = trajectory.sheetWidth
        let sheetHeight = trajectory.sheetHeight
        let columns = max(2, Int(sheetWidth / 5))
        let rows = 24
        var vertices: [Float] = []
        vertices.reserveCapacity((columns + 1) * (rows + 1) * 4)
        for row in 0...rows {
            let v = Float(row) / Float(rows)
            for column in 0...columns {
                let u = Float(column) / Float(columns)
                vertices.append(contentsOf: [u * sheetWidth, v * sheetHeight, u, v])
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
        leafVertexBuffer = vertexBuffer
        leafIndexBuffer = indexBuffer
        leafIndexCount = indices.count

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

        super.init(frame: CGRect(origin: .zero, size: sizePoints), device: device)
        colorPixelFormat = Self.colorFormat
        depthStencilPixelFormat = Self.depthFormat
        sampleCount = Self.msaaSampleCount
        clearDepth = 0
        isOpaque = true
        isUserInteractionEnabled = false
        isPaused = true
        enableSetNeedsDisplay = false
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// A snapshot can have any pixel format (for example 16 bits per channel). If the texture
    /// loader rejects it, the image is redrawn into the expected 8-bit format and loaded again,
    /// instead of silently cancelling the curl.
    static func texture(from image: UIImage, loader: MTKTextureLoader) -> MTLTexture? {
        guard let cgImage = image.cgImage else { return nil }
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
        ]
        if cgImage.bitsPerComponent == 8,
           let texture = try? loader.newTexture(cgImage: cgImage, options: options) {
            return texture
        }
        guard let normalized = normalizedRaster(cgImage) else { return nil }
        return try? loader.newTexture(cgImage: normalized, options: options)
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

    public func start() {
        startTime = CACurrentMediaTime()
        // The first frame (an exact copy of the current spread) is drawn synchronously and presented
        // within the current Core Animation transaction. Metal presents asynchronously, so otherwise
        // the host's swap of the spread under the overlay reaches the screen before the first frame,
        // and the target page flashes.
        (layer as? CAMetalLayer)?.presentsWithTransaction = true
        draw()
        (layer as? CAMetalLayer)?.presentsWithTransaction = false
        isPaused = false
        preferredFramesPerSecond = framesPerSecond > 0
            ? framesPerSecond
            : (window?.screen.maximumFramesPerSecond ?? 60)
    }
}

extension PageCurlOverlayView: MTKViewDelegate {

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        let elapsed = CACurrentMediaTime() - startTime
        let progress = Float(min(max(elapsed / duration, 0), 1))
        // Single-page backward: the forward trajectory with time reversed.
        let trajectoryProgress = (isSpread || forward) ? progress : 1 - progress

        guard let descriptor = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

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
        encoder.setVertexBuffer(leafVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CurlUniforms>.size, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CurlUniforms>.size, index: 1)
        encoder.setFragmentTexture(leafTexture, index: 0)
        encoder.setFragmentTexture(targetTexture, index: 1)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: leafIndexCount,
            indexType: .uint32,
            indexBuffer: leafIndexBuffer,
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

        if progress >= 1, !finished {
            finished = true
            isPaused = true
            onFinished?()
        }
    }
}
