import Foundation

/// Field order and types must match `CurlUniforms` in the shader.
struct CurlUniforms {
    var foldX: Float = 0
    var r0: Float = 0
    var k: Float = 0
    var halfWidth: Float = 0
    var height: Float = 0
    var zScale: Float = 0
    var zEpsilon: Float = 0
    var direction: Float = 1
    var originX: Float = 0
    var isSingle: Float = 0
    var backMix: Float = 0.22
    var paperR: Float = 1
    var paperG: Float = 1
    var paperB: Float = 1
    var shadowAmp: Float = 0
    var pad1: Float = 0
}

/// Curl geometry over the animation progress. Kept free of Metal so it can be tested on plain numbers.
struct CurlTrajectory {
    /// Half the screen for a spread, the whole screen for a single page.
    let sheetWidth: Float
    let sheetHeight: Float
    let screenHalfWidth: Float
    let isSpread: Bool
    /// +1: the leaf moves left of its edge; −1: mirrored.
    let direction: Float
    let paper: (r: Float, g: Float, b: Float)
    let startRadiusFraction: Float
    let coneStrength: Float
    let shadowStrength: Float
    let backMirrorOpacity: Float

    /// At both ends the fold is off screen with a margin for the visible arc, so the sheet looks flat.
    var foldStart: Float { sheetWidth + curlStartRadius * 1.2 + 8 }
    var foldEnd: Float { isSpread ? 0 : -(curlStartRadius * 1.2 + 8) }
    var curlStartRadius: Float { sheetWidth * startRadiusFraction }

    func uniforms(atProgress t: Float) -> CurlUniforms {
        let eased = t * t * (3 - 2 * t)
        var u = CurlUniforms()
        u.foldX = foldStart + (foldEnd - foldStart) * eased
        // A spread's radius shrinks almost to zero so the leaf ends as an exact mirror; a single
        // page keeps its radius and leaves the screen entirely. The final 1.0 must stay above the
        // shader's lower clamp that guards against division by zero.
        u.r0 = isSpread ? (curlStartRadius * (1 - eased) + 1.0 * eased) : curlStartRadius
        u.k = coneStrength * sin(.pi * eased)
        u.halfWidth = screenHalfWidth
        u.height = sheetHeight
        u.zScale = 1.0 / (curlStartRadius * 4)
        u.zEpsilon = 0.002
        u.direction = direction
        u.originX = isSpread ? screenHalfWidth : 0
        u.isSingle = isSpread ? 0 : 1
        u.backMix = backMirrorOpacity
        u.paperR = paper.r
        u.paperG = paper.g
        u.paperB = paper.b
        u.shadowAmp = shadowStrength * sin(.pi * eased)
        return u
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
            startRadiusFraction: Float(
                isSpread
                    ? configuration.spreadStartRadiusFraction
                    : configuration.singleStartRadiusFraction
            ),
            coneStrength: Float(configuration.coneStrength),
            shadowStrength: Float(configuration.shadowStrength),
            backMirrorOpacity: Float(configuration.backMirrorOpacity)
        )
    }
}
