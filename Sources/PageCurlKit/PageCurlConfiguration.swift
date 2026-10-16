import UIKit

/// Curl parameters. Can be changed on a live controller; changes apply from the next turn. The
/// paper color is not here: it comes from `PageCurlHost.paperColor`.
public struct PageCurlConfiguration {
    /// Animation length. Also the minimum interval between completed turns: a turn requested sooner
    /// happens instantly.
    public var duration: CFTimeInterval = 0.45

    /// Initial curl radius for a spread, as a fraction of the sheet width.
    public var spreadStartRadiusFraction: CGFloat = 0.16

    /// Initial curl radius for a single page, as a fraction of the sheet width.
    public var singleStartRadiusFraction: CGFloat = 0.10

    public var coneStrength: CGFloat = 0.05

    public var shadowStrength: CGFloat = 0.30

    /// Single page only: how much the page content shows through its back.
    public var backMirrorOpacity: CGFloat = 0.22

    /// 0 means the device maximum.
    public var preferredFramesPerSecond: Int = 0

    /// Spine shadow style for spreads; nil turns it off. Unlike the fields above, the library does
    /// not draw it: the host adds a `SpineShadowView` to its spread views, and the snapshots carry
    /// it into the animation.
    public var spineShadow: SpineShadowStyle? = SpineShadowStyle()

    public init() {}
}
