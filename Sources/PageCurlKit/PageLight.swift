import CoreGraphics
import simd

/// The one lamp over the book: how the paper's tone follows its slope. The shader has no light rule
/// of its own; it reads the tables made here.
enum PageLight {
    /// Toward the lamp, unit length, in screen axes: x right, y down, z toward the reader.
    static func lamp(_ configuration: PageCurlConfiguration) -> SIMD3<Float> {
        let angle = Float(configuration.lampAngle) * .pi / 180
        let elevation = Float(configuration.lampElevation) * .pi / 180
        return SIMD3(cos(angle) * cos(elevation), -sin(angle) * cos(elevation), sin(elevation))
    }

    /// The tone of paper whose normal makes `cosine` with the lamp: 1 where it faces the lamp as
    /// much as a flat page does or more, darker where it turns away.
    static func tone(cosine: Float, _ configuration: PageCurlConfiguration) -> Float {
        let flat = lamp(configuration).z
        let light = min(1, max(cosine, 0) / flat)
        return 1 - Float(configuration.leafTone) * (1 - light)
    }

    // How the shader table is laid out: the tone by cosine, from `lowestCosine` up to that of a flat
    // page (past it the tone stays 1), then the spine band from the spine outward on the left page
    // and on the right page.
    static let toneSamples = 256
    static let lowestCosine: Float = -1
    static let bandSamples = 64
    static let leftBandStart = toneSamples
    static let rightBandStart = toneSamples + bandSamples

    static func toneTable(_ configuration: PageCurlConfiguration) -> [Float] {
        let flat = lamp(configuration).z
        return (0..<toneSamples).map { index in
            let share = Float(index) / Float(toneSamples - 1)
            return tone(cosine: lowestCosine + (flat - lowestCosine) * share, configuration)
        }
    }

    /// The spine's band: darkest at the spine, as dark there as the leaf's shadow at its edge
    /// (`CurlShadowStyle.strength`), fading evenly to nothing at half
    /// the band's width. The lamp deepens the side whose paper, sloping into the binding, turns away
    /// from it and lightens the side that faces it, as much as `lampInfluence` says.
    static func gutterTone(
        distance: Float, leftOfSpine: Bool, _ configuration: PageCurlConfiguration
    ) -> Float {
        guard let style = configuration.spineShadow else { return 1 }
        let half = Float(style.width) / 2
        guard half > 0, distance < half else { return 1 }
        let share = 1 - distance / half
        let tilt = Float(30) * .pi / 180 * share
        let side: Float = leftOfSpine ? 1 : -1
        let lamp = lamp(configuration)
        let cosine = simd_dot(SIMD3(side * sin(tilt), 0, cos(tilt)), lamp)
        let turn = (cosine - lamp.z) / lamp.z
        let strength = Float(configuration.shadow.strength)
        let dark = strength * share * max(0, 1 - Float(style.lampInfluence) * turn)
        return 1 - dark
    }

    /// The spine band's tone from the spine outward to half the band's width, evenly sampled.
    static func spineBand(_ configuration: PageCurlConfiguration) -> (left: [Float], right: [Float]) {
        let half = Float((configuration.spineShadow ?? SpineShadowStyle()).width) / 2
        let distances = (0..<bandSamples).map { half * Float($0) / Float(bandSamples - 1) }
        return (
            distances.map { gutterTone(distance: $0, leftOfSpine: true, configuration) },
            distances.map { gutterTone(distance: $0, leftOfSpine: false, configuration) }
        )
    }

    static func shaderTable(_ configuration: PageCurlConfiguration) -> [Float] {
        let band = spineBand(configuration)
        return toneTable(configuration) + band.left + band.right
    }
}
