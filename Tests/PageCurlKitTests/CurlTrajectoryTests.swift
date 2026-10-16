import XCTest
@testable import PageCurlKit

/// At both ends of the trajectory the sheet must be flat: the fold is past the sheet edge and the
/// shadow is gone.
final class CurlTrajectoryTests: XCTestCase {

    private func spread(
        radiusFraction: Float = 0.16, shadowStrength: Float = 0.30, backMirrorOpacity: Float = 0.22
    ) -> CurlTrajectory {
        CurlTrajectory(
            sheetWidth: 400, sheetHeight: 600, screenHalfWidth: 400,
            isSpread: true, direction: 1, paper: (1, 1, 1),
            startRadiusFraction: radiusFraction, coneStrength: 0.05,
            shadowStrength: shadowStrength, backMirrorOpacity: backMirrorOpacity
        )
    }

    private func single() -> CurlTrajectory {
        CurlTrajectory(
            sheetWidth: 800, sheetHeight: 600, screenHalfWidth: 400,
            isSpread: false, direction: 1, paper: (1, 1, 1),
            startRadiusFraction: 0.10, coneStrength: 0.05,
            shadowStrength: 0.30, backMirrorOpacity: 0.22
        )
    }

    func testStartFrameIsFlat() {
        for trajectory in [spread(), single()] {
            let u = trajectory.uniforms(atProgress: 0)
            XCTAssertGreaterThan(
                u.foldX, trajectory.sheetWidth,
                "At t=0 the fold is beyond the far edge — the sheet is flat"
            )
            XCTAssertEqual(u.shadowAmp, 0, accuracy: 0.001, "No shadow at the flat end")
            XCTAssertEqual(u.k, 0, accuracy: 0.001, "No cone at the flat end")
        }
    }

    func testSpreadEndFrameIsExactMirror() {
        let trajectory = spread()
        let u = trajectory.uniforms(atProgress: 1)
        XCTAssertEqual(u.foldX, 0, accuracy: 0.001, "The fold reached the spine")
        XCTAssertEqual(u.r0, 1, accuracy: 0.001, "The radius decayed: the leaf lies as an exact mirror")
        XCTAssertEqual(u.shadowAmp, 0, accuracy: 0.001)
    }

    func testSingleEndFrameIsBeyondLeftEdge() {
        let trajectory = single()
        let u = trajectory.uniforms(atProgress: 1)
        XCTAssertLessThan(u.foldX, 0, "The single leaf left the screen entirely")
        XCTAssertEqual(u.shadowAmp, 0, accuracy: 0.001)
    }

    func testConeRisesMidwayAndSubsides() {
        let trajectory = spread()
        let mid = trajectory.uniforms(atProgress: 0.5)
        XCTAssertGreaterThan(mid.k, 0, "The cone rises midway")
        XCTAssertGreaterThan(mid.shadowAmp, 0, "The shadow is visible midway")
    }

    func testConfigurationDrivesGeometry() {
        let standard = spread()
        XCTAssertGreaterThan(spread(radiusFraction: 0.30).curlStartRadius, standard.curlStartRadius)

        let mid = standard.uniforms(atProgress: 0.5)
        XCTAssertGreaterThan(
            spread(shadowStrength: 0.60).uniforms(atProgress: 0.5).shadowAmp, mid.shadowAmp
        )
        XCTAssertNotEqual(
            spread(backMirrorOpacity: 0.5).uniforms(atProgress: 0.5).backMix, mid.backMix
        )
    }
}
