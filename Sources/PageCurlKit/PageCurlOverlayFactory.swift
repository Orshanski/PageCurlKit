import UIKit
import Metal

/// A snapshot already in the curl view's memory. The controller only keeps it and hands it back in
/// a request, so it knows nothing about how the view stores it.
protocol LoadedSnapshot: AnyObject {}

struct PageCurlOverlayRequest {
    let currentSpread: LoadedSnapshot
    let targetSpread: LoadedSnapshot
    let sizePoints: CGSize
    let forward: Bool
    let isSpread: Bool
    let paperColor: UIColor
    let configuration: PageCurlConfiguration
}

/// The curl view as the controller uses it: one view, loaded and run again for every turn.
@MainActor
protocol PageCurlOverlayAnimating: UIView {
    var onFinished: (() -> Void)? { get set }
    /// Moves the snapshot's pixels into the view's memory once; nil — it could not be loaded. The
    /// image is not kept.
    func load(_ snapshot: UIImage) -> LoadedSnapshot?
    /// Takes one turn and its size; false — this turn cannot be animated.
    func prepare(_ request: PageCurlOverlayRequest) -> Bool
    func startIfFirstFrameDrawn() -> Bool
    /// Stops drawing, drops `onFinished` and the turn's snapshots, so an interrupted run cannot
    /// finish the next one and a finished one does not keep snapshots the controller let go.
    func stop()
    /// Frees the render targets; the next frame allocates them again.
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
        guard let device = MTLCreateSystemDefaultDevice() else {
            curlLog.error("curl view not made: no Metal device")
            return nil
        }
        return PageCurlOverlayView(device: device)
    }
}
