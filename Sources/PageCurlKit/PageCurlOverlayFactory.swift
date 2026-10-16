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
}

extension PageCurlOverlayView: PageCurlOverlayAnimating {}

@MainActor
protocol PageCurlOverlayFactory {
    var isAvailable: Bool { get }
    func warmUp()
    func makeOverlay(_ request: PageCurlOverlayRequest) -> PageCurlOverlayAnimating?
}

/// Without a Metal device the controller always turns instantly.
@MainActor
final class MetalOverlayFactory: PageCurlOverlayFactory {
    private let device = MTLCreateSystemDefaultDevice()

    var isAvailable: Bool { device != nil }

    func warmUp() {
        guard let device else { return }
        PageCurlOverlayView.warmUp(device: device)
    }

    func makeOverlay(_ request: PageCurlOverlayRequest) -> PageCurlOverlayAnimating? {
        guard let device else { return nil }
        return PageCurlOverlayView(
            device: device,
            currentSpread: request.currentSpread,
            targetSpread: request.targetSpread,
            sizePoints: request.sizePoints,
            forward: request.forward,
            isSpread: request.isSpread,
            paperColor: request.paperColor,
            configuration: request.configuration
        )
    }
}
