import XCTest
import UIKit
@testable import PageCurlKit

/// The controller asks the host for views only for what the snapshot cache lacks.
@MainActor
final class ControllerCacheTests: ControllerTestCase {

    func testPrefetchSnapshotsOnlyWhatIsMissing() async {
        host.nextView = nil
        controller.prefetch()
        XCTAssertEqual(host.currentViewCalls, 1)
        XCTAssertEqual(host.neighbourCalls, [true, false])

        controller.prefetch()
        XCTAssertEqual(host.currentViewCalls, 1, "A matching position and size are not re-snapshotted")
        XCTAssertEqual(host.neighbourCalls, [true, false, true], "Only the missing neighbour is asked again")

        host.nextView = Self.spreadView(size: containerSize)
        controller.prefetch()
        controller.prefetch()
        XCTAssertEqual(host.neighbourCalls, [true, false, true, true], "Once there, it is kept")

        controller.invalidate()
        controller.prefetch()
        XCTAssertEqual(host.currentViewCalls, 2, "After invalidate the cache is rebuilt")

        host.position = FakeHost.Position(value: 7)
        controller.prefetch()
        XCTAssertEqual(host.currentViewCalls, 3, "A position change rebuilds the cache")

        resizeContainer(to: CGSize(width: 600, height: 800))
        controller.prefetch()
        XCTAssertEqual(host.currentViewCalls, 4, "A size change rebuilds the cache")
    }

    func testTurnShiftsCacheInsteadOfResnapshotting() async {
        controller.prefetch()
        XCTAssertEqual(host.currentViewCalls, 1)
        XCTAssertEqual(host.neighbourCalls.count, 2)
        await completeBeautifulTurn(forward: true)
        XCTAssertEqual(host.currentViewCalls, 1, "A ready cache is not re-snapshotted on a tap")
        XCTAssertEqual(host.neighbourCalls, [true, false, true], "Only the new neighbour ahead is snapshotted")
        time += 10
        await completeBeautifulTurn(forward: false)
        XCTAssertEqual(host.currentViewCalls, 1, "Turning back reuses the old current snapshot")
        XCTAssertEqual(host.neighbourCalls, [true, false, true, false])

        let first = overlay.requests[0]
        let back = overlay.requests[1]
        XCTAssertTrue(back.currentSpread === first.targetSpread, "The first turn's target became current")
        XCTAssertTrue(back.targetSpread === first.currentSpread, "Turning back leads to where it came from")
    }

    func testPrefetchedSnapshotsAreNotLoadedAgainOnTurn() async {
        controller.prefetch()
        XCTAssertEqual(overlay.loads, 3, "The spread on screen and both neighbours")
        controller.turn(forward: true, isSpread: false)
        XCTAssertEqual(overlay.runs, 1)
        XCTAssertEqual(overlay.loads, 3, "Neither the current nor the target snapshot is loaded on a tap")
        await waitUntil("show under the overlay") { host.showTargetCalls.count == 1 }
        overlay.finish()
        await host.drain()
    }

    func testAfterTurnNextTurnEitherWayUsesLoadedSnapshots() async {
        for forward in [true, false] {
            makeFixture()
            controller.prefetch()
            await completeBeautifulTurn(forward: true)
            let loadsBefore = overlay.loads
            time += 10
            controller.turn(forward: forward, isSpread: false)
            XCTAssertEqual(overlay.runs, 2, "forward \(forward): the animated path")
            XCTAssertEqual(overlay.loads, loadsBefore, "forward \(forward): nothing is loaded on a tap")
            XCTAssertTrue(
                overlay.requests[1].currentSpread === overlay.requests[0].targetSpread,
                "forward \(forward): the first turn's target is now current"
            )
            await waitUntil("show under the overlay") { host.showTargetCalls.count == 2 }
            overlay.finish()
            await host.drain()
        }
    }

    func testPrefetchWaitsForCurlEndAndRestartsOnRelease() async {
        controller.turn(forward: true, isSpread: false)
        await waitUntil("show") { host.showTargetCalls.count == 1 }
        let callsDuringCurl = host.neighbourCalls.count
        controller.prefetch()
        XCTAssertEqual(host.neighbourCalls.count, callsDuringCurl, "No rebuild while the curl is running")
        overlay.finish()
        XCTAssertGreaterThan(host.neighbourCalls.count, callsDuringCurl, "release() restarts the rebuild")
        await host.drain()
    }
}
