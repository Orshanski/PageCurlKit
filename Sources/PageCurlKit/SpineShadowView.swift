import UIKit

/// A soft vertical shadow down the middle of a spread, like the fold of a paper book.
public struct SpineShadowStyle: Equatable {
    public var width: CGFloat = 44
    public var strength: CGFloat = 0.12

    public init() {}
}

/// The host adds this view to its own spread views over the spine (see `frame(forSpreadBounds:style:)`).
/// Snapshots then include the shadow, so the curl animation needs nothing extra.
public final class SpineShadowView: UIView {

    public var style: SpineShadowStyle {
        didSet { applyColors() }
    }

    private let gradient = CAGradientLayer()

    public init(style: SpineShadowStyle = SpineShadowStyle()) {
        self.style = style
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

    public static func frame(forSpreadBounds bounds: CGRect, style: SpineShadowStyle) -> CGRect {
        CGRect(
            x: bounds.midX - style.width / 2, y: bounds.minY,
            width: style.width, height: bounds.height
        )
    }

    private func applyColors() {
        // No implicit animation, so a live style change follows a slider without lag.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(style.strength).cgColor,
            UIColor.black.withAlphaComponent(0).cgColor,
        ]
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
