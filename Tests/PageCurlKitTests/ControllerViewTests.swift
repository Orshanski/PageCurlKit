import XCTest
import UIKit
@testable import PageCurlKit

/// The controller keeps one curl view and tells it exactly which turn to play.
@MainActor
final class ControllerViewTests: ControllerTestCase {

    func testOneViewForAllTurns() async {
        controller.warmUp()
        await completeBeautifulTurn()
        time += 10
        await completeBeautifulTurn()
        XCTAssertEqual(factory.makeCalls, 1, "The view is made once and reused")
    }

    func testBackgroundReleasesRenderTargets() async {
        controller.warmUp()
        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        XCTAssertEqual(overlay.renderTargetReleases, 1, "Going to the background frees the render targets")
    }

    func testViewHoldsNoSnapshotsAfterTheTurnEnds() async {
        controller.turn(forward: true, isSpread: false)
        XCTAssertEqual(overlay.heldSnapshots.count, 2, "The running turn holds its snapshots")
        await waitUntil("show under the overlay") { host.showTargetCalls.count == 1 }
        overlay.finish()
        XCTAssertTrue(overlay.heldSnapshots.isEmpty, "A finished turn leaves nothing in the view")
        await host.drain()
    }

    func testViewHoldsNoSnapshotsAfterANewTurnInterrupts() async {
        controller.turn(forward: true, isSpread: false)
        await waitUntil("first show") { host.showTargetCalls.count == 1 }
        controller.turn(forward: true, isSpread: false)
        XCTAssertEqual(overlay.runs, 1, "The repeat call goes the instant way")
        XCTAssertTrue(overlay.heldSnapshots.isEmpty, "An interrupted turn leaves nothing in the view")
        await host.drain()
    }

    func testViewHoldsNoSnapshotsAfterBackgroundMidTurn() async {
        controller.turn(forward: true, isSpread: false)
        await waitUntil("show") { host.showTargetCalls.count == 1 }
        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        XCTAssertTrue(overlay.heldSnapshots.isEmpty, "Nothing stays in the view in the background")
        await host.drain()
    }

    func testRequestDescribesTheTurn() async {
        host.paperColor = .black
        container.backgroundColor = .white
        await completeBeautifulTurn(forward: true, isSpread: false)
        time += 10
        await completeBeautifulTurn(forward: false, isSpread: true)

        let single = overlay.requests[0]
        XCTAssertEqual(single.paperColor, .black, "Paper comes from the host, not the container")
        XCTAssertTrue(single.forward)
        XCTAssertFalse(single.isSpread)
        XCTAssertEqual(single.sizePoints, containerSize)

        let spread = overlay.requests[1]
        XCTAssertFalse(spread.forward)
        XCTAssertTrue(spread.isSpread)
        XCTAssertEqual(spread.sizePoints, containerSize)
    }
}
