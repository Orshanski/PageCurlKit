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

        // The first frame shows the current spread; the leaf's shading may darken it slightly.
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
            // Drawables are reused, so the one handed out may still show an earlier turn.
            if let texture = mtkView.currentDrawable?.texture {
                let zeros = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
                texture.replace(
                    region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                    mipmapLevel: 0, withBytes: zeros, bytesPerRow: texture.width * 4
                )
            }
            view.draw(in: mtkView)
            drawn = mtkView.currentDrawable?.texture
        }

        func firstFrame(current: LoadedSnapshot, target: LoadedSnapshot, forward: Bool) throws -> [UInt8] {
            let size = CGSize(width: side, height: side)
            XCTAssertTrue(view.prepare(PageCurlOverlayRequest(
                currentSpread: current, targetSpread: target, sizePoints: size,
                forward: forward, isSpread: false, paperColor: .white,
                configuration: PageCurlConfiguration()
            )))
            drawn = nil
            XCTAssertTrue(view.startIfFirstFrameDrawn())
            view.stop()
            let texture = try XCTUnwrap(drawn, "No frame was drawn")
            // The first frame is committed and only scheduled; wait for the GPU to write it.
            var pixel = [UInt8](repeating: 0, count: 4)
            for _ in 0..<200 {
                texture.getBytes(
                    &pixel, bytesPerRow: 4,
                    from: MTLRegionMake2D(side / 2, side / 2, 1, 1), mipmapLevel: 0
                )
                if pixel != [0, 0, 0, 0] { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return pixel
        }
    }
}
