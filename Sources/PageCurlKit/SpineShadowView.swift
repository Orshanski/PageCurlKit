import UIKit

/// A soft band down the middle of a spread, like the fold of a paper book; the lamp makes the side
/// turned away from it a little deeper and the other a little lighter.
public struct SpineShadowStyle: Equatable {
    /// The whole band across the spine, in points; half of it on each page.
    public var width: CGFloat = 32
    /// How much the lamp changes the band; 0 — both sides alike.
    public var lampInfluence: CGFloat = 0.5

    public init() {}
}

/// The host adds this view to its own spread views over the spine (see
/// `frame(forSpreadBounds:configuration:)`). The curl leaves it out of its snapshots and draws the
/// same band itself, on the still pages and on the turning leaf.
public final class SpineShadowView: UIView {

    public var configuration: PageCurlConfiguration {
        didSet { applyColors() }
    }

    private let gradient = CAGradientLayer()

    public init(configuration: PageCurlConfiguration = PageCurlConfiguration()) {
        self.configuration = configuration
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        applyColors()
        layer.addSublayer(gradient)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    public static func frame(
        forSpreadBounds bounds: CGRect, configuration: PageCurlConfiguration
    ) -> CGRect {
        let width = (configuration.spineShadow ?? SpineShadowStyle()).width
        return CGRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: bounds.height)
    }

    private func applyColors() {
        // The same samples the curl's shader reads, so a still spread and the curl's first frame
        // match.
        let band = PageLight.spineBand(configuration)
        let last = Double(band.left.count - 1)
        var colors: [CGColor] = []
        var locations: [NSNumber] = []
        for (index, tone) in band.left.reversed().enumerated() {
            colors.append(UIColor.black.withAlphaComponent(CGFloat(1 - tone)).cgColor)
            locations.append(NSNumber(value: 0.5 * Double(index) / last))
        }
        for (index, tone) in band.right.enumerated() {
            colors.append(UIColor.black.withAlphaComponent(CGFloat(1 - tone)).cgColor)
            locations.append(NSNumber(value: 0.5 + 0.5 * Double(index) / last))
        }
        // No implicit animation, so a live change follows a slider without lag.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = colors
        gradient.locations = locations
        CATransaction.commit()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }
}
