import XCTest
import MetalKit
@testable import PageCurlKit

/// Snapshot textures of the curl view. Needs a Metal device.
@MainActor
final class PageCurlOverlayViewTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        return device
    }

    func testSixteenBitSnapshotStillLoadsAsTexture() throws {
        let image = UIImage(cgImage: try SnapshotRasterTests.sixteenBitImage())
        let texture = try PageCurlOverlayView.makeTexture(from: image, device: try device())
        XCTAssertEqual(texture.width, 8)
        XCTAssertEqual(texture.height, 8)
    }

    func testTextureHoldsTheRasterBytes() throws {
        let image = UIImage(cgImage: try SnapshotRasterTests.redImage(
            bitsPerComponent: 8, bitmapInfo: SnapshotRasterTests.bgraInfo
        ))
        let texture = try PageCurlOverlayView.makeTexture(from: image, device: try device())
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        XCTAssertEqual(pixel, [0, 0, 255, 255], "Copied as they are, no re-encoding")
    }

    func testSnapshotsLoadedOnceAreDrawnInEveryTurn() throws {
        let view = try XCTUnwrap(PageCurlOverlayView(device: try device()))
        let frames = FrameGrabber(view)
        let red = try XCTUnwrap(view.load(Self.image(.red)))
        let blue = try XCTUnwrap(view.load(Self.image(.blue)))

        // The first frame shows the current spread. On a leaf this small the shading next to the
        // fold reaches the centre and darkens it slightly.
        assertColor(try frames.firstFrame(current: red, target: blue, forward: true), [0, 0, 255, 255])
        assertColor(try frames.firstFrame(current: blue, target: red, forward: false), [255, 0, 0, 255])
        assertColor(try frames.firstFrame(current: red, target: blue, forward: true), [0, 0, 255, 255])
    }

    private func assertColor(
        _ pixel: [UInt8], _ expected: [UInt8], file: StaticString = #filePath, line: UInt = #line
    ) {
        let close = pixel.count == expected.count
            && zip(pixel, expected).allSatisfy { abs(Int($0) - Int($1)) <= 8 }
        XCTAssertTrue(close, "\(pixel) is not \(expected)", file: file, line: line)
    }

    func testStopLetsGoOfTheTurnSnapshots() throws {
        let view = try XCTUnwrap(PageCurlOverlayView(device: try device()))
        let frames = FrameGrabber(view)
        weak var current: MTLTexture?
        weak var target: MTLTexture?
        try autoreleasepool {
            let red = try XCTUnwrap(view.load(Self.image(.red)))
            let blue = try XCTUnwrap(view.load(Self.image(.blue)))
            current = (red as? SnapshotTexture)?.texture
            target = (blue as? SnapshotTexture)?.texture
            // No frame is drawn: a submitted frame would hold the textures until some unknown
            // moment after the GPU finishes it.
            frames.prepare(current: red, target: blue, forward: true)
            view.stop()
        }
        XCTAssertNil(current, "After stop() the view keeps no snapshot of the turn")
        XCTAssertNil(target, "After stop() the view keeps no snapshot of the turn")
    }

    func testRunningTurnHoldsItsSnapshotsItself() throws {
        let view = try XCTUnwrap(PageCurlOverlayView(device: try device()))
        let frames = FrameGrabber(view)
        try autoreleasepool {
            let red = try XCTUnwrap(view.load(Self.image(.red)))
            let blue = try XCTUnwrap(view.load(Self.image(.blue)))
            frames.prepare(current: red, target: blue, forward: true)
        }
        // Nobody else holds the snapshots now, as after a memory warning mid-turn.
        assertColor(try frames.drawFirstFrame(), [0, 0, 255, 255])
    }

    private static let side = 8

    private static func image(_ color: UIColor) -> UIImage {
        let format = SnapshotRaster.rendererFormat()
        format.scale = 1
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Plays one turn's first frame and reads back the centre pixel of what was drawn, B, G, R, A.
    @MainActor
    private final class FrameGrabber: NSObject, MTKViewDelegate {
        private let view: PageCurlOverlayView
        private var drawn: MTLTexture?

        init(_ view: PageCurlOverlayView) {
            self.view = view
            super.init()
            view.framebufferOnly = false
            view.delegate = self
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in mtkView: MTKView) {
            view.draw(in: mtkView)
            drawn = mtkView.currentDrawable?.texture
        }

        func firstFrame(current: LoadedSnapshot, target: LoadedSnapshot, forward: Bool) throws -> [UInt8] {
            prepare(current: current, target: target, forward: forward)
            return try drawFirstFrame()
        }

        func prepare(current: LoadedSnapshot, target: LoadedSnapshot, forward: Bool) {
            let size = CGSize(width: side, height: side)
            XCTAssertTrue(view.prepare(PageCurlOverlayRequest(
                currentSpread: current, targetSpread: target, sizePoints: size,
                forward: forward, isSpread: false, paperColor: .white,
                configuration: PageCurlConfiguration()
            )))
        }

        /// Draws the prepared turn's first frame and stops the view.
        func drawFirstFrame() throws -> [UInt8] {
            drawn = nil
            let started = view.startIfFirstFrameDrawn()
            view.stop()
            let texture = try XCTUnwrap(started ? drawn : nil, "The first frame was not drawn")
            // A copy on the same queue starts only after the frame has written the texture, but only
            // when Metal tracks that texture; otherwise the pixel could be read before the write.
            XCTAssertEqual(
                texture.hazardTrackingMode, .tracked,
                "The frame texture is not tracked (mode \(texture.hazardTrackingMode.rawValue)), so its pixel cannot be read safely"
            )
            guard texture.hazardTrackingMode == .tracked else { return [] }
            let device = try XCTUnwrap(view.device)
            let pixel = try XCTUnwrap(device.makeBuffer(length: 4, options: .storageModeShared))
            let commands = try XCTUnwrap(view.commandQueue.makeCommandBuffer())
            let blit = try XCTUnwrap(commands.makeBlitCommandEncoder())
            blit.copy(
                from: texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: side / 2, y: side / 2, z: 0),
                sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                to: pixel, destinationOffset: 0, destinationBytesPerRow: 4, destinationBytesPerImage: 4
            )
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            return Array(UnsafeBufferPointer(
                start: pixel.contents().assumingMemoryBound(to: UInt8.self), count: 4
            ))
        }
    }
}
