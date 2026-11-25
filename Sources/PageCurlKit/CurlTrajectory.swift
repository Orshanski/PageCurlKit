import Foundation

/// Field order and types must match `CurlUniforms` in the shader.
struct CurlUniforms {
    /// Cone angle, radians; π/2 is a flat sheet.
    var theta: Float = .pi / 2
    /// Cone apex on the spine line, sheet points from the top edge; always above the sheet.
    var apexY: Float = 0
    /// Rotation of the whole leaf about the spine, radians.
    var rotation: Float = 0
    /// +1 — the cone tight at the top corner, 0 — the cylinder, −1 — the cone tight at the bottom.
    var conic: Float = 0
    var cylinderRadius: Float = 0
    var width: Float = 0
    var height: Float = 0
    var eyeDistance: Float = 0
    var direction: Float = 1
    var originX: Float = 0
    var halfWidth: Float = 0
    var isSingle: Float = 0
    var backMix: Float = 0
    var paperR: Float = 1
    var paperG: Float = 1
    var paperB: Float = 1
    /// 0 — no shadow.
    var shadowStrength: Float = 0
    /// Screen points the shadow moves per point of the leaf's height.
    var shadowShiftX: Float = 0
    var shadowShiftY: Float = 0
    var shadowSoftening: Float = 0
    var shadowMaxWidth: Float = 0
    var shadowMinimumWidth: Float = 0
    /// The softest level made for this frame.
    var shadowTopLevel: Float = 0
    /// Toward the lamp, unit length, in screen axes: y down, z toward the reader.
    var lampX: Float = 0
    var lampY: Float = 0
    var lampZ: Float = 1
    /// 0 — the leaf keeps the page's tone.
    var leafTone: Float = 0
    /// 0 — no slope into the binding: a single page, or the spine shadow is off.
    var gutterHalfWidth: Float = 0
}

/// A pose of the leaf in the units of Microsoft's Project Austin: angles in degrees, the apex in
/// steps of their page grid, which is 30 steps wide and 40 tall.
struct CurlPose: Equatable {
    var theta: Float
    var apexY: Float
    var rotation: Float
    var conic: Float

    static let gridHeight: Float = 40
}

/// Austin's page curl (journal/views/page_curl.cpp, Apache 2.0), driven by a finger that nobody
/// holds: it is played once at their 60 frames per second and kept as a list of poses.
struct CurlPoseTrack {
    /// Austin's `paperParams`: finger x from 1 (outer edge) to 0 (spine) gives θ, Ay and the rotation.
    private static let fingerX: [Float] = [0, 0.1666, 0.3333, 0.8333, 0.95, 1]
    /// Austin drops θ from 90° to 60° at full slope as soon as the finger moves, which bends the
    /// whole leaf at once; here θ leaves 90° with no slope, so the leaf starts to bend gradually.
    private static let theta = MonotoneCurve(
        x: fingerX, y: [20, 25, 45, 55, 60, 90], startsFlatAtLastPoint: true
    )
    private static let apexY = MonotoneCurve(x: fingerX, y: [-40, -30, -10, -4, -5, -20])
    private static let rotation = MonotoneCurve(x: fingerX, y: [95, 60, 35, 13, 0, 0])

    /// How long the finger travels from the outer edge to the spine, in Austin's milliseconds.
    static let fingerMilliseconds: Float = 800

    private static let frameMilliseconds: Float = 1000 / 60
    private static let maxStep: Float = 5

    static func paperPose(fingerX x: Float, fingerY y: Float) -> CurlPose {
        CurlPose(theta: theta(x), apexY: apexY(x), rotation: rotation(x), conic: y)
    }

    /// Austin's `onRender`: one frame moves the pose at most `maxStep` toward the target.
    static func step(from current: CurlPose, toward next: CurlPose) -> CurlPose {
        let d = (
            next.theta - current.theta, next.apexY - current.apexY,
            next.rotation - current.rotation, next.conic - current.conic
        )
        let distance = (d.0 * d.0 + d.1 * d.1 + d.2 * d.2 + d.3 * d.3).squareRoot()
        guard distance >= maxStep else { return next }
        let scale = maxStep / distance
        return CurlPose(
            theta: current.theta + scale * d.0, apexY: current.apexY + scale * d.1,
            rotation: current.rotation + scale * d.2, conic: current.conic + scale * d.3
        )
    }

    let poses: [CurlPose]
    /// How far the leaf has gone at each pose, counting the bend (θ) and the turn about the spine
    /// (ρ) in degrees.
    let travelled: [Float]

    /// `fingerHeight` from −1 (bottom edge) to +1 (top edge); Austin takes it as the cone share.
    /// With `conicReturns` the shape goes back to a full cone after the release, as in Austin.
    init(fingerHeight: Float, conicReturns: Bool) {
        typealias Track = CurlPoseTrack
        var poses: [CurlPose] = []
        let frames = Int((Track.fingerMilliseconds / Track.frameMilliseconds).rounded())
        var current = Track.paperPose(fingerX: 1, fingerY: fingerHeight)
        for frame in 0...frames {
            let u = Float(frame) / Float(frames)
            // The finger starts from rest and reaches the spine still moving.
            current = Track.step(
                from: current, toward: Track.paperPose(fingerX: 1 - u * u, fingerY: fingerHeight)
            )
            poses.append(current)
        }

        // Austin's `startAutoCurl` lets the page fall from rest. Here its clock starts where the fall
        // is as fast as the finger was, so the leaf does not stop at the release.
        let fingerSpeed = poses[poses.count - 1].rotation - poses[poses.count - 2].rotation
        var time = (max(fingerSpeed, 0) * 200_000).squareRoot()
        // Austin stops at 100° and hides the page; ours keeps falling until it lies on the other
        // side. Past 100° θ opens to 90° along ρ, starting at the slope Austin's rule had there.
        var opening: (theta: Float, slope: Float)?
        while current.rotation < 180 {
            let gain = time * time
            var next = current
            next.rotation = min(current.rotation + gain / 200_000, 180)
            if next.rotation <= 100 {
                next.theta = min(current.theta + gain / 800_000, 50)
            } else {
                let start = opening ?? (current.theta, current.theta < 50 ? 0.25 : 0)
                opening = start
                next.theta = Track.hermite(
                    from: start.theta, to: 90, startSlope: start.slope * 80, endSlope: 0,
                    at: (next.rotation - 100) / 80
                )
            }
            if conicReturns {
                next.conic = current.conic > 0
                    ? min(current.conic + gain / 100_000, 1)
                    : max(current.conic - gain / 100_000, -1)
            }
            current = Track.step(from: current, toward: next)
            poses.append(current)
            time += Track.frameMilliseconds
        }
        self.poses = poses
        var travelled: [Float] = [0]
        for (a, b) in zip(poses, poses.dropFirst()) {
            let step = ((b.theta - a.theta) * (b.theta - a.theta)
                + (b.rotation - a.rotation) * (b.rotation - a.rotation)).squareRoot()
            travelled.append(travelled[travelled.count - 1] + step)
        }
        self.travelled = travelled
    }

    /// Share of the run spent speeding up, and as much slowing down at the end.
    private static let easing: Float = 0.2

    /// How far along the track the leaf is at `progress` of the turn: it speeds up evenly, goes at
    /// one speed, then slows down evenly, rather than at the pace of Austin's finger.
    private static func distanceShare(atProgress p: Float) -> Float {
        let a = easing
        let top = 1 / (1 - a)
        if p < a { return top * p * p / (2 * a) }
        if p > 1 - a { return 1 - top * (1 - p) * (1 - p) / (2 * a) }
        return top * (a / 2 + p - a)
    }

    /// The pose at a share of the turn, between Austin's frames by straight lines.
    func pose(atProgress progress: Float) -> CurlPose {
        let target = Self.distanceShare(atProgress: progress) * travelled[travelled.count - 1]
        var low = 0
        var high = travelled.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if travelled[middle] <= target { low = middle } else { high = middle }
        }
        let span = travelled[high] - travelled[low]
        let f = span > 0 ? min(max((target - travelled[low]) / span, 0), 1) : 0
        let a = poses[low]
        let b = poses[high]
        return CurlPose(
            theta: a.theta + (b.theta - a.theta) * f,
            apexY: a.apexY + (b.apexY - a.apexY) * f,
            rotation: a.rotation + (b.rotation - a.rotation) * f,
            conic: a.conic + (b.conic - a.conic) * f
        )
    }

    private static func hermite(
        from p0: Float, to p1: Float, startSlope m0: Float, endSlope m1: Float, at s: Float
    ) -> Float {
        let s2 = s * s
        let s3 = s2 * s
        return (2 * s3 - 3 * s2 + 1) * p0 + (s3 - 2 * s2 + s) * m0
            + (-2 * s3 + 3 * s2) * p1 + (s3 - s2) * m1
    }
}

/// A smooth curve through points that never swings past its neighbours (Fritsch–Carlson).
struct MonotoneCurve {
    let x: [Float]
    let y: [Float]
    let slopes: [Float]

    init(x: [Float], y: [Float], startsFlatAtLastPoint: Bool = false) {
        let n = x.count
        let h = (0..<(n - 1)).map { x[$0 + 1] - x[$0] }
        let d = (0..<(n - 1)).map { (y[$0 + 1] - y[$0]) / h[$0] }
        var m = [Float](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) where d[i - 1] * d[i] > 0 {
            let w1 = 2 * h[i] + h[i - 1]
            let w2 = h[i] + 2 * h[i - 1]
            m[i] = (w1 + w2) / (w1 / d[i - 1] + w2 / d[i])
        }
        self.x = x
        self.y = y
        if startsFlatAtLastPoint {
            m[n - 1] = 0
        }
        slopes = m
    }

    func callAsFunction(_ t: Float) -> Float {
        let t = min(max(t, x[0]), x[x.count - 1])
        var i = 0
        while i < x.count - 2, t > x[i + 1] { i += 1 }
        let h = x[i + 1] - x[i]
        let s = (t - x[i]) / h
        let s2 = s * s
        let s3 = s2 * s
        return (2 * s3 - 3 * s2 + 1) * y[i] + (s3 - 2 * s2 + s) * h * slopes[i]
            + (-2 * s3 + 3 * s2) * y[i + 1] + (s3 - s2) * h * slopes[i + 1]
    }
}

/// One turn: the poses of `CurlPoseTrack` laid onto a sheet of a given size.
struct CurlTrajectory {
    /// Half the screen for a spread, the whole screen for a single page.
    let sheetWidth: Float
    let sheetHeight: Float
    let screenHalfWidth: Float
    let isSpread: Bool
    /// +1: the leaf moves left of its edge; −1: mirrored.
    let direction: Float
    let paper: (r: Float, g: Float, b: Float)
    let backMirrorOpacity: Float
    let track: CurlPoseTrack
    let cylinderRadiusScale: Float
    /// The eye looks at the screen centre from this far, in screen heights.
    let eyeDistanceToHeight: Float
    let shadow: CurlShadowStyle
    let lamp: SIMD3<Float>
    let leafTone: Float
    let spineShadow: SpineShadowStyle?
    let lightTable: [Float]

    /// A lifted leaf is never farther from the screen than its width, so the eye stays beyond that.
    var eyeDistance: Float {
        max(sheetHeight * eyeDistanceToHeight, sheetWidth * 1.5)
    }

    func uniforms(atProgress t: Float) -> CurlUniforms {
        uniforms(for: track.pose(atProgress: t))
    }

    func uniforms(for pose: CurlPose) -> CurlUniforms {
        let gridStep = sheetHeight / CurlPose.gridHeight
        let theta = pose.theta * .pi / 180
        var u = CurlUniforms()
        u.theta = theta
        u.apexY = pose.apexY * gridStep
        u.rotation = pose.rotation * .pi / 180
        u.conic = pose.conic
        u.cylinderRadius = cylinderRadius(theta: theta, apexY: pose.apexY) * gridStep
            * cylinderRadiusScale
        u.width = sheetWidth
        u.height = sheetHeight
        u.eyeDistance = eyeDistance
        u.direction = direction
        u.originX = isSpread ? screenHalfWidth : 0
        u.halfWidth = screenHalfWidth
        u.isSingle = isSpread ? 0 : 1
        u.backMix = backMirrorOpacity
        u.paperR = paper.r
        u.paperG = paper.g
        u.paperB = paper.b
        u.lampX = lamp.x
        u.lampY = lamp.y
        u.lampZ = lamp.z
        u.leafTone = leafTone
        if isSpread, let spineShadow {
            u.gutterHalfWidth = Float(spineShadow.width) / 2
        }
        if shadow.isEnabled {
            // The whole shadow fades as the leaf comes down flat at either end of the turn, so no
            // line is left along its edge; while the leaf is up, it is full even at the spine.
            let rise = sheetWidth * max(sin(u.rotation), cos(theta))
            let t = min(max(rise / 60, 0), 1)
            u.shadowStrength = Float(shadow.strength) * t * t * (3 - 2 * t)
            // The shadow falls away from the lamp, farther the lower the lamp stands.
            u.shadowShiftX = -lamp.x / lamp.z
            u.shadowShiftY = -lamp.y / lamp.z
            u.shadowSoftening = Float(shadow.softening)
            u.shadowMaxWidth = Float(shadow.maxWidth)
            u.shadowMinimumWidth = Float(shadow.minimumWidth)
        }
        return u
    }

    /// Austin's cylinder radius, in grid steps: the cone's radius at the far edge, half way down.
    /// As θ opens from 50° to 90° Austin lets it grow to 200 steps; here the bend fades to none
    /// instead, so a leaf at θ = 90° lies exactly flat at both ends of the turn.
    private func cylinderRadius(theta: Float, apexY: Float) -> Float {
        let width = sheetWidth / sheetHeight * CurlPose.gridHeight
        let half = CurlPose.gridHeight / 2 - apexY
        let reach = (width * width + half * half).squareRoot()
        let at50: Float = 50 * .pi / 180
        guard theta > at50 else { return reach * sin(theta) }
        let bendLeft = (.pi / 2 - theta) / (.pi / 2 - at50)
        return reach * sin(at50) / max(bendLeft, 1e-6)
    }
}

extension CurlTrajectory {
    /// Only a spread turned backward curls mirrored: its leaf moves right, away from the spine.
    static func direction(isSpread: Bool, forward: Bool) -> Float {
        (isSpread && !forward) ? -1 : 1
    }

    /// The trajectory of one turn on a container of `sizePoints`.
    init(
        sizePoints: CGSize, isSpread: Bool, forward: Bool,
        paper: (r: Float, g: Float, b: Float), configuration: PageCurlConfiguration
    ) {
        self.init(
            sheetWidth: isSpread ? Float(sizePoints.width / 2) : Float(sizePoints.width),
            sheetHeight: Float(sizePoints.height),
            screenHalfWidth: Float(sizePoints.width / 2),
            isSpread: isSpread,
            direction: Self.direction(isSpread: isSpread, forward: forward),
            paper: paper,
            backMirrorOpacity: Float(configuration.backMirrorOpacity),
            track: CurlPoseTrack(
                fingerHeight: Float(configuration.coneShare),
                conicReturns: configuration.coneReturnsAfterRelease
            ),
            cylinderRadiusScale: Float(configuration.cylinderRadiusScale),
            eyeDistanceToHeight: Float(configuration.eyeDistance),
            shadow: configuration.shadow,
            lamp: PageLight.lamp(configuration),
            leafTone: Float(configuration.leafTone),
            spineShadow: configuration.spineShadow,
            lightTable: PageLight.shaderTable(configuration)
        )
    }
}
