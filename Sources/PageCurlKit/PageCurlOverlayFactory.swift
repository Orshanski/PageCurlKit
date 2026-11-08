import UIKit
import Metal

struct PageCurlOverlayRequest {
    let currentSpread: UIImage
    let targetSpread: UIImage
    let sizePoints: CGSize
    let forward: Bool
    let isSpread: Bool
    let paperColor: UIColor
    let configuration: PageCurlConfiguration
}

/// Lets tests substitute a lightweight overlay without Metal and finish the animation themselves.
@MainActor
protocol PageCurlOverlayAnimating: UIView {
    var onFinished: (() -> Void)? { get set }
    func start()
    /// Draws the first frame and starts the animation; false — the first frame did not reach the
    /// screen and the animation did not start.
    func startIfFirstFrameDrawn() -> Bool
    /// Stops drawing and drops `onFinished`, so an interrupted run cannot finish the next one.
    func stop()
}

extension PageCurlOverlayAnimating {
    func startIfFirstFrameDrawn() -> Bool {
        start()
        return true
    }

    func stop() {
        onFinished = nil
    }
}

extension PageCurlOverlayView: PageCurlOverlayAnimating {}

@MainActor
protocol PageCurlOverlayFactory {
    var isAvailable: Bool { get }
    func warmUp()
    /// Called once per turn; the returned view may be the same one every time.
    func makeOverlay(_ request: PageCurlOverlayRequest) -> PageCurlOverlayAnimating?
}

/// Without a Metal device the controller always turns instantly.
@MainActor
final class MetalOverlayFactory: PageCurlOverlayFactory {
    private let device = MTLCreateSystemDefaultDevice()
    /// One view for every turn: its textures and render targets are allocated once and refilled.
    private var overlay: PageCurlOverlayView?

    var isAvailable: Bool { device != nil }

    func warmUp() {
        guard let device else { return }
        PageCurlOverlayView.warmUp(device: device)
        if overlay == nil {
            overlay = PageCurlOverlayView(device: device)
        }
    }

    func makeOverlay(_ request: PageCurlOverlayRequest) -> PageCurlOverlayAnimating? {
        guard let device else { return nil }
        if overlay == nil {
            overlay = PageCurlOverlayView(device: device)
        }
        guard let overlay, overlay.prepare(
            currentSpread: request.currentSpread,
            targetSpread: request.targetSpread,
            sizePoints: request.sizePoints,
            forward: request.forward,
            isSpread: request.isSpread,
            paperColor: request.paperColor,
            configuration: request.configuration
        ) else { return nil }
        return overlay
    }
}
