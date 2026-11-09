import XCTest
import Metal
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
        let texture = try PageCurlOverlayView.loadSnapshot(image, reusing: nil, device: try device())
        XCTAssertEqual(texture.width, 8)
        XCTAssertEqual(texture.height, 8)
    }

    func testTextureReusedAtSameSizeAndReplacedAtAnother() throws {
        let device = try device()
        let small = UIImage(cgImage: try SnapshotRasterTests.redImage(
            bitsPerComponent: 8, bitmapInfo: SnapshotRasterTests.bgraInfo
        ))
        let first = try PageCurlOverlayView.loadSnapshot(small, reusing: nil, device: device)
        let again = try PageCurlOverlayView.loadSnapshot(small, reusing: first, device: device)
        XCTAssertTrue(again === first, "Same size: the texture is refilled, not made again")

        let large = UIImage(cgImage: try SnapshotRasterTests.redImage(
            bitsPerComponent: 8, bitmapInfo: SnapshotRasterTests.bgraInfo, width: 16, height: 16
        ))
        let other = try PageCurlOverlayView.loadSnapshot(large, reusing: first, device: device)
        XCTAssertFalse(other === first, "Another size: a new texture")
        XCTAssertEqual(other.width, 16)
        XCTAssertEqual(other.height, 16)
    }

    func testTextureHoldsTheRasterBytes() throws {
        let image = UIImage(cgImage: try SnapshotRasterTests.redImage(
            bitsPerComponent: 8, bitmapInfo: SnapshotRasterTests.bgraInfo
        ))
        let texture = try PageCurlOverlayView.loadSnapshot(image, reusing: nil, device: try device())
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        XCTAssertEqual(pixel, [0, 0, 255, 255], "Copied as they are, no re-encoding")
    }
}
