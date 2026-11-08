import XCTest
import CoreGraphics
import Metal
@testable import PageCurlKit

/// A snapshot can have any pixel format, such as 16 bits per channel; the library must convert it
/// rather than silently cancel the curl. The texture holds 8-bit BGRA bytes.
final class RasterNormalizationTests: XCTestCase {

    private func makeImage(bitsPerComponent: Int, bitmapInfo: UInt32, width: Int = 8, height: Int = 8) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: bitsPerComponent, bytesPerRow: 0, space: space,
            bitmapInfo: bitmapInfo
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeSixteenBitImage() throws -> CGImage {
        try makeImage(bitsPerComponent: 16, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        return device
    }

    private func firstPixel(_ texture: MTLTexture) -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        return pixel
    }

    func testSixteenBitRasterNormalizesToEightBit() throws {
        let source = try makeSixteenBitImage()
        XCTAssertEqual(source.bitsPerComponent, 16, "The fixture must be a 16-bit-per-channel image")

        let normalized = try XCTUnwrap(PageCurlOverlayView.normalizedRaster(source))
        XCTAssertEqual(normalized.bitsPerComponent, 8)
        XCTAssertEqual(normalized.bitsPerPixel, 32)
        XCTAssertEqual(normalized.width, source.width)
        XCTAssertEqual(normalized.height, source.height)
    }

    @MainActor
    func testSixteenBitSnapshotStillLoadsAsTexture() throws {
        let image = UIImage(cgImage: try makeSixteenBitImage())
        let texture = try XCTUnwrap(
            PageCurlOverlayView.loadSnapshot(image, reusing: nil, device: try device())
        )
        XCTAssertEqual(texture.width, 8)
        XCTAssertEqual(texture.height, 8)
        XCTAssertEqual(firstPixel(texture), [0, 0, 255, 255], "Red as B, G, R, A")
    }

    @MainActor
    func testRendererSnapshotBytesAreBGRA() throws {
        // The same kind of snapshot the controller takes.
        let format = UIGraphicsImageRendererFormat.preferred()
        format.preferredRange = .standard
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let texture = try XCTUnwrap(
            PageCurlOverlayView.loadSnapshot(image, reusing: nil, device: try device())
        )
        XCTAssertEqual(firstPixel(texture), [0, 0, 255, 255], "Red as B, G, R, A")
    }

    @MainActor
    func testRGBASnapshotIsReorderedToBGRA() throws {
        let source = try makeImage(
            bitsPerComponent: 8,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
        let texture = try XCTUnwrap(
            PageCurlOverlayView.loadSnapshot(UIImage(cgImage: source), reusing: nil, device: try device())
        )
        XCTAssertEqual(firstPixel(texture), [0, 0, 255, 255], "Red as B, G, R, A")
    }

    @MainActor
    func testTextureReusedAtSameSizeAndReplacedAtAnother() throws {
        let device = try device()
        let small = UIImage(cgImage: try makeImage(
            bitsPerComponent: 8,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        let first = try XCTUnwrap(PageCurlOverlayView.loadSnapshot(small, reusing: nil, device: device))
        let again = try XCTUnwrap(PageCurlOverlayView.loadSnapshot(small, reusing: first, device: device))
        XCTAssertTrue(again === first, "Same size: the texture is refilled, not made again")

        let large = UIImage(cgImage: try makeImage(
            bitsPerComponent: 8,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
            width: 16, height: 16
        ))
        let other = try XCTUnwrap(PageCurlOverlayView.loadSnapshot(large, reusing: first, device: device))
        XCTAssertFalse(other === first, "Another size: a new texture")
        XCTAssertEqual(other.width, 16)
        XCTAssertEqual(other.height, 16)
    }
}
