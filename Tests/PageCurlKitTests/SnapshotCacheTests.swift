import XCTest
@testable import PageCurlKit

/// The cache on plain values: positions are numbers, snapshots are names.
final class SnapshotCacheTests: XCTestCase {

    private let size = CGSize(width: 800, height: 600)

    private func full(at position: Int = 5) -> SnapshotCache<Int, String> {
        SnapshotCache(position: position, size: size, current: "on screen", next: "ahead", previous: "behind")
    }

    func testValidOnlyForItsPositionAndSize() {
        let cache = full()
        XCTAssertTrue(cache.isValid(for: 5, size: size))
        XCTAssertFalse(cache.isValid(for: 6, size: size))
        XCTAssertFalse(cache.isValid(for: 5, size: CGSize(width: 600, height: 800)))
    }

    func testPairIsCurrentAndTheNeighbourInTheTurnDirection() {
        let cache = full()
        XCTAssertEqual(cache.pair(forward: true)?.current, "on screen")
        XCTAssertEqual(cache.pair(forward: true)?.target, "ahead")
        XCTAssertEqual(cache.pair(forward: false)?.target, "behind")
    }

    func testMissingNeighbourGivesNoPairAndCanBeFilledLater() {
        var cache = SnapshotCache<Int, String>(position: 5, size: size, current: "on screen")
        XCTAssertNil(cache.neighbour(forward: true))
        XCTAssertNil(cache.pair(forward: true))
        cache.setNeighbour("ahead", forward: true)
        XCTAssertEqual(cache.pair(forward: true)?.target, "ahead")
        XCTAssertNil(cache.neighbour(forward: false), "Filling one side leaves the other alone")
    }

    func testForwardShiftMakesTheTargetCurrent() throws {
        let shifted = try XCTUnwrap(full().shifted(forward: true, from: 5, to: 6))
        XCTAssertEqual(shifted.position, 6)
        XCTAssertEqual(shifted.size, size)
        XCTAssertEqual(shifted.current, "ahead", "The former target is now on screen")
        XCTAssertEqual(shifted.previous, "on screen", "The former current is now behind")
        XCTAssertNil(shifted.next, "The new neighbour ahead is unknown")
    }

    func testBackwardShiftMakesTheTargetCurrent() throws {
        let shifted = try XCTUnwrap(full().shifted(forward: false, from: 5, to: 4))
        XCTAssertEqual(shifted.position, 4)
        XCTAssertEqual(shifted.current, "behind")
        XCTAssertEqual(shifted.next, "on screen")
        XCTAssertNil(shifted.previous)
    }

    func testNoShiftWhenTheCacheDoesNotDescribeTheTurn() {
        XCTAssertNil(full().shifted(forward: true, from: 5, to: 5), "Nothing was shown")
        XCTAssertNil(full().shifted(forward: true, from: 4, to: 5), "The cache is for another position")
        let noTarget = SnapshotCache<Int, String>(position: 5, size: size, current: "on screen")
        XCTAssertNil(noTarget.shifted(forward: true, from: 5, to: 6), "The target was never snapshotted")
    }
}
