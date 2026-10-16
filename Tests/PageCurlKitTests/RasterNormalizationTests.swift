import XCTest
import CoreGraphics
import MetalKit
@testable import PageCurlKit

/// A snapshot can have any pixel format, such as 16 bits per channel. The texture loader rejects
/// it, so the library must convert it rather than silently cancel the curl.
final class RasterNormalizationTests: XCTestCase {

    private func makeSixteenBitImage(width: Int = 8, height: Int = 8) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 16, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
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
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let image = UIImage(cgImage: try makeSixteenBitImage())
        let texture = try XCTUnwrap(
            PageCurlOverlayView.texture(from: image, loader: MTKTextureLoader(device: device))
        )
        XCTAssertEqual(texture.width, 8)
        XCTAssertEqual(texture.height, 8)
    }
}
