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

/// The curl view as the controller uses it: one view, loaded and run again for every turn. Tests
/// substitute a lightweight one without Metal and finish the animation themselves.
@MainActor
protocol PageCurlOverlayAnimating: UIView {
    var onFinished: (() -> Void)? { get set }
    /// Loads one turn and takes its size; false — this turn cannot be animated.
    func prepare(_ request: PageCurlOverlayRequest) -> Bool
    func startIfFirstFrameDrawn() -> Bool
    /// Stops drawing and drops `onFinished`, so an interrupted run cannot finish the next one.
    func stop()
    /// Frees the snapshot textures and render targets; the next `prepare` allocates them again.
    func releaseTextures()
}

@MainActor
protocol PageCurlOverlayFactory {
    /// The controller asks until it gets a view and then keeps that view for all its turns.
    func makeOverlay() -> PageCurlOverlayAnimating?
}

/// Without a Metal device there is no view, and the controller always turns instantly.
@MainActor
struct MetalOverlayFactory: PageCurlOverlayFactory {
    func makeOverlay() -> PageCurlOverlayAnimating? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return PageCurlOverlayView(device: device)
    }
}
