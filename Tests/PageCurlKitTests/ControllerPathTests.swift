import XCTest
import UIKit
@testable import PageCurlKit

/// Every call shows something: when the curl is not possible, the turn goes the instant way.
@MainActor
final class ControllerPathTests: ControllerTestCase {

    func testEveryFallbackShowsInstantly() async {
        let fallbacks: [(name: String, arrange: @MainActor (ControllerPathTests) -> Void)] = [
            ("busy host", { $0.host.canTurnOverride = false }),
            ("no curl view", { $0.factory.isAvailable = false }),
            ("view not prepared", { $0.overlay.failNextPrepare = true }),
            // Not ready or the edge: the tap still does not get swallowed.
            ("no neighbour", { $0.host.nextView = nil }),
            // A call before anything is shown.
            ("no current spread", { $0.host.currentView = nil }),
            ("current snapshot not loaded", { $0.overlay.successfulLoadsLeft = 0 }),
            ("target snapshot not loaded", { $0.overlay.successfulLoadsLeft = 1 }),
        ]
        for fallback in fallbacks {
            makeFixture()
            fallback.arrange(self)
            controller.turn(forward: true, isSpread: false)
            XCTAssertEqual(overlay.runs, 0, "\(fallback.name): no curl")
            XCTAssertNil(overlay.superview, "\(fallback.name): no overlay on screen")
            await waitUntil("\(fallback.name): instant show") { host.showTargetCalls == [true] }
            await host.drain()
        }
    }

    func testUndrawnFirstFrameShowsInstantlyWithoutOverlay() async {
        overlay.failFirstFrame = true
        controller.turn(forward: true, isSpread: false)
        XCTAssertNil(overlay.superview, "An undrawn first frame leaves no overlay on screen")
        XCTAssertEqual(overlay.runs, 0)
        await waitUntil("instant show") { host.showTargetCalls == [true] }
        await host.drain()
        // No run is left behind: prefetch is not held back by a curl that never started.
        let neighbourCallsBefore = host.neighbourCalls.count
        controller.prefetch()
        XCTAssertGreaterThan(host.neighbourCalls.count, neighbourCallsBefore)

        overlay.failFirstFrame = false
        time += 10
        await completeBeautifulTurn()
    }

    func testEmptyCacheAssembledOnTheSpot() async {
        // Without any prefetch a tap still gets the animated path.
        controller.turn(forward: true, isSpread: false)
        XCTAssertEqual(overlay.runs, 1)
        XCTAssertEqual(host.currentViewCalls, 1)
        XCTAssertEqual(host.neighbourCalls, [true], "On-the-spot assembly takes only the needed direction")
        await waitUntil("show under the overlay") { host.showTargetCalls == [true] }
        overlay.finish()
        await host.drain()
    }

    // MARK: - Rapid tapping and the edge of the book

    func testUnexpiredQuietWindowShowsInstantly() async {
        await completeBeautifulTurn()
        controller.turn(forward: true, isSpread: false)
        XCTAssertEqual(overlay.runs, 1, "No second curl within the quiet window")
        await waitUntil("show via the instant path") { host.showTargetCalls.count == 2 }
        await host.drain()
        time += 1
        controller.turn(forward: true, isSpread: false)
        XCTAssertEqual(overlay.runs, 2)
        await waitUntil("show under the second curl") { host.showTargetCalls.count == 3 }
        overlay.finish()
        await host.drain()
    }

    func testEdgeTapDoesNotArmQuietWindow() async {
        // A tap at the edge shows nothing, so it does not start the interval and the reverse tap
        // curls right away.
        host.nextView = nil
        host.showTargetResult = { forward in !forward }
        controller.turn(forward: true, isSpread: false)
        await waitUntil("the silent edge show") { host.showTargetCalls == [true] }
        await host.drain()
        XCTAssertEqual(overlay.runs, 0)

        controller.turn(forward: false, isSpread: false)
        XCTAssertEqual(overlay.runs, 1, "The silent edge tap did not arm the window — backward curls")
        await waitUntil("show backward") { host.showTargetCalls == [true, false] }
        overlay.finish()
        await host.drain()
    }
}
