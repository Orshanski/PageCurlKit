import XCTest
@testable import PageCurlKit

/// What lies where in each of the four kinds of turn.
final class CurlSceneTests: XCTestCase {

    private typealias Background = CurlScene.Background

    func testSceneTable() {
        struct Row {
            let isSpread: Bool
            let forward: Bool
            let backgrounds: [Background]
            let leafFace: CurlSnapshot
            let reversesTime: Bool
            let counterClockwise: Bool
        }
        let rows = [
            // The left half stays, the right half reveals the next spread.
            Row(isSpread: true, forward: true,
                backgrounds: [Background(quad: .left, snapshot: .current), Background(quad: .right, snapshot: .target)],
                leafFace: .current, reversesTime: false, counterClockwise: true),
            // Mirrored: the right half stays, the left half reveals the previous spread.
            Row(isSpread: true, forward: false,
                backgrounds: [Background(quad: .left, snapshot: .target), Background(quad: .right, snapshot: .current)],
                leafFace: .current, reversesTime: false, counterClockwise: false),
            // The page curls away over the next one.
            Row(isSpread: false, forward: true,
                backgrounds: [Background(quad: .full, snapshot: .target)],
                leafFace: .current, reversesTime: false, counterClockwise: true),
            // The previous page curls back in over the current one.
            Row(isSpread: false, forward: false,
                backgrounds: [Background(quad: .full, snapshot: .current)],
                leafFace: .target, reversesTime: true, counterClockwise: true),
        ]
        for row in rows {
            let scene = CurlScene(isSpread: row.isSpread, forward: row.forward)
            let name = "spread \(row.isSpread), forward \(row.forward)"
            XCTAssertEqual(scene.backgrounds, row.backgrounds, name)
            XCTAssertEqual(scene.leafFace, row.leafFace, name)
            XCTAssertEqual(scene.leafBack, .target, name)
            XCTAssertEqual(scene.reversesTime, row.reversesTime, name)
            XCTAssertEqual(scene.frontFacesCounterClockwise, row.counterClockwise, name)
        }
    }

    func testFirstFrameShowsTheCurrentSpread() {
        // At the first frame the leaf lies flat, so what is visible must be the current spread:
        // on a spread the leaf covers the half that is not current.
        for (isSpread, forward) in [(true, true), (true, false), (false, true), (false, false)] {
            let scene = CurlScene(isSpread: isSpread, forward: forward)
            let start = scene.trajectoryProgress(0)
            if scene.reversesTime {
                XCTAssertEqual(start, 1, "Reversed: starts with the leaf gone, the current page underneath")
                XCTAssertEqual(scene.backgrounds.map(\.snapshot), [.current])
            } else {
                XCTAssertEqual(start, 0)
                XCTAssertEqual(scene.leafFace, .current, "Flat leaf at the start shows the current spread")
            }
        }
    }

    func testReversedTimeRunsBackward() {
        let scene = CurlScene(isSpread: false, forward: false)
        XCTAssertEqual(scene.trajectoryProgress(0.25), 0.75)
        XCTAssertEqual(CurlScene(isSpread: true, forward: false).trajectoryProgress(0.25), 0.25)
    }

    func testBackgroundQuadsCoverTheirHalves() {
        func xs(_ quad: BackgroundQuad) -> (min: Float, max: Float) {
            let x = stride(from: 0, to: quad.vertices.count, by: 4).map { quad.vertices[$0] }
            return (x.min()!, x.max()!)
        }
        func us(_ quad: BackgroundQuad) -> (min: Float, max: Float) {
            let u = stride(from: 2, to: quad.vertices.count, by: 4).map { quad.vertices[$0] }
            return (u.min()!, u.max()!)
        }
        XCTAssertTrue(xs(.left) == (-1, 0) && us(.left) == (0, 0.5))
        XCTAssertTrue(xs(.right) == (0, 1) && us(.right) == (0.5, 1))
        XCTAssertTrue(xs(.full) == (-1, 1) && us(.full) == (0, 1))
        for quad in BackgroundQuad.allCases {
            XCTAssertEqual(quad.vertices.count, 6 * 4, "Two triangles of (x, y, u, v)")
        }
    }
}
