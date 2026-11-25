import XCTest
@testable import PageCurlKit

/// At both ends of the trajectory the sheet must be flat: on its own side at the start, on the
/// other side at the end.
final class CurlTrajectoryTests: XCTestCase {

    private func spread(backMirrorOpacity: CGFloat = 0.22) -> CurlTrajectory {
        var configuration = PageCurlConfiguration()
        configuration.backMirrorOpacity = backMirrorOpacity
        return CurlTrajectory(
            sizePoints: CGSize(width: 800, height: 600), isSpread: true, forward: true,
            paper: (1, 1, 1), configuration: configuration
        )
    }

    private func single() -> CurlTrajectory {
        CurlTrajectory(
            sizePoints: CGSize(width: 800, height: 600), isSpread: false, forward: true,
            paper: (1, 1, 1), configuration: PageCurlConfiguration()
        )
    }

    func testStartFrameIsFlat() {
        for trajectory in [spread(), single()] {
            let u = trajectory.uniforms(atProgress: 0)
            XCTAssertEqual(u.theta, .pi / 2, "At t=0 the cone is flat")
            XCTAssertEqual(u.rotation, 0, "At t=0 the leaf lies on its own side")
        }
    }

    func testSpreadEndFrameIsExactMirror() {
        let trajectory = spread()
        let u = trajectory.uniforms(atProgress: 1)
        XCTAssertEqual(u.theta, .pi / 2, "The leaf is flat again: it lies as an exact mirror")
        XCTAssertEqual(u.rotation, .pi, "The leaf lies on the other side of the spine")
    }

    func testSingleEndFrameIsBeyondLeftEdge() {
        let trajectory = single()
        let u = trajectory.uniforms(atProgress: 1)
        XCTAssertEqual(u.rotation, .pi, "The single leaf turned past the left edge and left the screen")
        XCTAssertEqual(u.theta, .pi / 2)
    }

    func testConeRisesMidwayAndSubsides() {
        let trajectory = spread()
        let mid = trajectory.uniforms(atProgress: 0.5)
        XCTAssertLessThan(mid.theta, .pi / 2, "The cone rises midway")
    }

    // MARK: - From a turn

    private func turn(isSpread: Bool, forward: Bool) -> CurlTrajectory {
        CurlTrajectory(
            sizePoints: CGSize(width: 800, height: 600), isSpread: isSpread, forward: forward,
            paper: (1, 1, 1), configuration: PageCurlConfiguration()
        )
    }

    func testOnlyASpreadTurnedBackIsMirrored() {
        XCTAssertEqual(turn(isSpread: true, forward: true).direction, 1)
        XCTAssertEqual(turn(isSpread: true, forward: false).direction, -1)
        XCTAssertEqual(turn(isSpread: false, forward: true).direction, 1)
        XCTAssertEqual(turn(isSpread: false, forward: false).direction, 1, "Single backward reverses time instead")
    }

    func testSheetFollowsTheKindOfTurn() {
        let spread = turn(isSpread: true, forward: true)
        XCTAssertEqual(spread.sheetWidth, 400, "A spread's leaf is half the screen")
        let single = turn(isSpread: false, forward: true)
        XCTAssertEqual(single.sheetWidth, 800, "A single leaf is the whole screen")
        for trajectory in [spread, single] {
            XCTAssertEqual(trajectory.screenHalfWidth, 400)
            XCTAssertEqual(trajectory.sheetHeight, 600)
        }
    }

    func testConfigurationDrivesGeometry() {
        let mid = spread().uniforms(atProgress: 0.5)
        XCTAssertNotEqual(
            spread(backMirrorOpacity: 0.5).uniforms(atProgress: 0.5).backMix, mid.backMix
        )
    }
}
