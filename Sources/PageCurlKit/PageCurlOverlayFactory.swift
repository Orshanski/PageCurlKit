import UIKit
import Metal

/// A snapshot already in the curl view's memory. The controller only keeps it and hands it back in
/// a request, so it knows nothing about how the view stores it.
protocol LoadedSnapshot: AnyObject {
    /// The host's spread view had a `SpineShadowView` when this snapshot was taken.
    var showsSpineBand: Bool { get set }
}

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
    /// The same off the main thread; `completion` runs on the main thread.
    func loadInBackground(_ snapshot: UIImage, completion: @escaping @MainActor (LoadedSnapshot?) -> Void)
    /// Takes one turn and its size; false — this turn cannot be animated.
    func prepare(_ request: PageCurlOverlayRequest) -> Bool
    /// Makes what a turn of this size needs ahead of it, off the main thread.
    func prepareAhead(sizePoints: CGSize, scale: CGFloat, configuration: PageCurlConfiguration)
    func startIfFirstFrameDrawn() -> Bool
    /// Runs `action` once `count` frames of the running turn are drawn, or at once when the turn
    /// stops sooner.
    func afterFramesShown(_ count: Int, _ action: @escaping @MainActor () -> Void)
    /// Stops drawing, drops `onFinished` and the turn's snapshots, so an interrupted run cannot
    /// finish the next one and a finished one does not keep snapshots the controller let go.
    func stop()
    /// Frees the render targets; the next frame allocates them again.
    func releaseRenderTargets()
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
