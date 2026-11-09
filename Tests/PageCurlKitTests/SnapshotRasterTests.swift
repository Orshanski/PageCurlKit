import XCTest
import UIKit
@testable import PageCurlKit

/// A snapshot can have any pixel format; the raster is always 8-bit BGRA. Checked on bytes, without
/// a GPU.
final class SnapshotRasterTests: XCTestCase {

    static func redImage(bitsPerComponent: Int, bitmapInfo: UInt32, width: Int = 8, height: Int = 8) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: bitsPerComponent, bytesPerRow: 0, space: space,
            bitmapInfo: bitmapInfo
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    static func sixteenBitImage() throws -> CGImage {
        try redImage(bitsPerComponent: 16, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static let bgraInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    private func firstPixel(_ raster: SnapshotRaster) -> [UInt8] {
        Array(raster.bytes.prefix(4))
    }

    func testSixteenBitRasterNormalizesToEightBit() throws {
        let source = try Self.sixteenBitImage()
        XCTAssertEqual(source.bitsPerComponent, 16, "The fixture must be a 16-bit-per-channel image")

        let normalized = try XCTUnwrap(SnapshotRaster.redrawn(source))
        XCTAssertEqual(normalized.bitsPerComponent, 8)
        XCTAssertEqual(normalized.bitsPerPixel, 32)
        XCTAssertEqual(normalized.width, source.width)
        XCTAssertEqual(normalized.height, source.height)
        XCTAssertTrue(SnapshotRaster.fits(normalized), "The redrawn image is taken as is")
    }

    @MainActor
    func testRendererSnapshotIsTakenAsIsAndIsBGRA() throws {
        // The same kind of snapshot the controller takes.
        let format = SnapshotRaster.rendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        XCTAssertTrue(SnapshotRaster.fits(try XCTUnwrap(image.cgImage)), "No redraw for our own snapshots")
        let raster = try SnapshotRaster(image)
        XCTAssertEqual(firstPixel(raster), [0, 0, 255, 255], "Red as B, G, R, A")
    }

    func testRGBAIsReorderedToBGRA() throws {
        let source = try Self.redImage(
            bitsPerComponent: 8,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
        XCTAssertFalse(SnapshotRaster.fits(source), "RGBA bytes are not taken as they are")
        let raster = try SnapshotRaster(UIImage(cgImage: source))
        XCTAssertEqual(firstPixel(raster), [0, 0, 255, 255], "Red as B, G, R, A")
    }

    func testSixteenBitIsRedrawnToBGRA() throws {
        let raster = try SnapshotRaster(UIImage(cgImage: try Self.sixteenBitImage()))
        XCTAssertEqual(raster.width, 8)
        XCTAssertEqual(raster.height, 8)
        XCTAssertEqual(firstPixel(raster), [0, 0, 255, 255], "Red as B, G, R, A")
    }

    func testImageWithoutBitmapNamesTheReason() {
        XCTAssertThrowsError(try SnapshotRaster(UIImage())) { error in
            XCTAssertEqual(error as? SnapshotLoadFailure, .noBitmap)
        }
    }
}
