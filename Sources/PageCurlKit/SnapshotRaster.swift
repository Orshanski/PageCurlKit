import UIKit
import Metal

/// Why a snapshot did not become a texture.
enum SnapshotLoadFailure: String, Error {
    case noBitmap = "the image has no bitmap"
    case redrawFailed = "the image could not be redrawn as 8-bit BGRA"
    case noPixelBytes = "the bitmap gave no pixel bytes"
    case textureNotAllocated = "the texture was not allocated"
}

/// A snapshot's pixels as the curl reads them: 8 bits per channel, BGRA in memory, alpha first,
/// sRGB. The bytes are copied into the texture as they are, without sRGB re-encoding.
struct SnapshotRaster {
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: Data

    /// How to draw a view so its snapshot is already in this raster; a wide-color display would
    /// otherwise give 16 bits per channel.
    static func rendererFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.preferredRange = .standard
        return format
    }

    /// Takes the bytes as they are when they already fit, otherwise redraws the image first.
    init(_ image: UIImage) throws(SnapshotLoadFailure) {
        guard let source = image.cgImage else { throw .noBitmap }
        guard let raster = Self.fits(source) ? source : Self.redrawn(source) else {
            throw .redrawFailed
        }
        guard let data = raster.dataProvider?.data,
              CFDataGetLength(data) >= raster.bytesPerRow * raster.height
        else { throw .noPixelBytes }
        width = raster.width
        height = raster.height
        bytesPerRow = raster.bytesPerRow
        bytes = data as Data
    }

    static func fits(_ cgImage: CGImage) -> Bool {
        let alpha = cgImage.alphaInfo
        return cgImage.bitsPerComponent == 8
            && cgImage.bitsPerPixel == 32
            && cgImage.byteOrderInfo == .order32Little
            && (alpha == .premultipliedFirst || alpha == .noneSkipFirst)
    }

    static func redrawn(_ cgImage: CGImage) -> CGImage? {
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
}
