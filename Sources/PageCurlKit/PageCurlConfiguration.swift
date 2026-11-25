import UIKit

/// Curl parameters. Can be changed on a live controller; changes apply from the next turn. The
/// paper color is not here: it comes from `PageCurlHost.paperColor`.
public struct PageCurlConfiguration {
    /// Animation length. Also the minimum interval between completed turns: a turn requested sooner
    /// happens instantly, and the snapshots for the next curl wait until no tap came for this long.
    public var duration: CFTimeInterval = 0.75

    /// Shape of the bend: −1 tight at the bottom corner, 0 a cylinder, +1 tight at the top corner.
    public var coneShare: CGFloat = 0.6

    /// After the release the shape goes back to a full cone, as in Microsoft's Project Austin.
    public var coneReturnsAfterRelease = false

    /// 1 is Austin's cylinder; smaller bends tighter.
    public var cylinderRadiusScale: CGFloat = 0.6

    /// How far the eye is from the screen, in screen heights. Nearer makes the lifted leaf grow more.
    public var eyeDistance: CGFloat = 5

    /// Where the lamp is, in degrees counter-clockwise from the right as seen on the screen; 135 is
    /// top left. The leaf's shadow and tone both follow it.
    public var lampAngle: CGFloat = 135

    /// How high the lamp stands over the screen, in degrees; 90 is straight above.
    public var lampElevation: CGFloat = 45

    /// How much the leaf darkens where its surface turns away from the lamp; 0 turns it off.
    public var leafTone: CGFloat = 0.3

    /// The shadow the lifted leaf casts on the page under it. Its strength also sets the spine
    /// band's depth, so it stays when the shadow is turned off.
    public var shadow = CurlShadowStyle()

    /// Single page only: how much the page content shows through its back.
    public var backMirrorOpacity: CGFloat = 0.5

    /// 0 means the device maximum.
    public var preferredFramesPerSecond: Int = 0

    /// The band down the middle of a spread; nil turns it off. On a still spread the host draws it
    /// with a `SpineShadowView`; during a turn the curl draws it itself wherever the host's spread
    /// view has one. Turning it on or off drops the controller's snapshots and takes them again.
    public var spineShadow: SpineShadowStyle? = SpineShadowStyle()

    public init() {}
}

/// The leaf's shadow on the page: the leaf seen from a lamp, softer where the leaf is higher.
public struct CurlShadowStyle: Equatable {
    /// The leaf casts its shadow on the page.
    public var isEnabled = true
    /// How much darker the page is under the edge of the shadow.
    public var strength: CGFloat = 0.18
    /// How much wider the soft edge grows per point of the leaf's height.
    public var softening: CGFloat = 0.3
    /// The widest the soft edge gets, in points.
    public var maxWidth: CGFloat = 85
    /// The narrowest the soft edge gets, in points: where the leaf is fixed at the spine the
    /// shadow ends in a soft falloff rather than a line.
    public var minimumWidth: CGFloat = 8

    public init() {}
}
