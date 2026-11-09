import XCTest
import UIKit
@testable import PageCurlKit

/// A running curl can be cut short; the host's queue must never stay held by a curl that is gone.
@MainActor
final class ControllerInterruptionTests: ControllerTestCase {

    func testRepeatTurnInterruptsAndStillShows() async {
        controller.turn(forward: true, isSpread: false)
        XCTAssertNotNil(overlay.superview)
        await waitUntil("first show") { host.showTargetCalls.count == 1 }

        controller.turn(forward: true, isSpread: false)
        XCTAssertNil(overlay.superview, "The running curl is interrupted")
        XCTAssertEqual(overlay.runs, 1, "A repeat call goes the instant way")
        await waitUntil("second show") { host.showTargetCalls.count == 2 }
        await host.drain()
    }

    func testInterruptIsIdempotent() async {
        controller.interrupt()
        controller.interrupt()

        controller.turn(forward: true, isSpread: false)
        await waitUntil("show") { host.showTargetCalls.count == 1 }
        controller.interrupt()
        XCTAssertNil(overlay.superview)
        controller.interrupt()
        await host.drain()
    }

    func testBackgroundNotificationInterrupts() async {
        controller.turn(forward: true, isSpread: false)
        await waitUntil("show") { host.showTargetCalls.count == 1 }
        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        XCTAssertNil(overlay.superview, "Backgrounding interrupts the curl")
        await host.drain()
    }

    func testContainerResizeInterrupts() async {
        controller.turn(forward: true, isSpread: false)
        await waitUntil("show") { host.showTargetCalls.count == 1 }
        resizeContainer(to: CGSize(width: 600, height: 800))
        XCTAssertNil(overlay.superview, "A container resize interrupts the curl")
        await host.drain()
    }

    func testControllerDeathMidCurlReleasesHeldStep() async {
        // The pager is closed mid-curl: the controller dies while its step holds the queue. The
        // step must finish rather than hang forever.
        controller.turn(forward: true, isSpread: false)
        await waitUntil("show") { host.showTargetCalls.count == 1 }
        for _ in 0..<50 { await Task.yield() }
        controller = nil
        await waitUntil("the held step released") { host.pendingSteps == 0 }
    }

    func testInterruptedHeldStepDoesNotHoldTheNextRun() async {
        host.canTurnOverride = true
        controller.turn(forward: true, isSpread: false)
        await waitUntil("first show") { host.showTargetCalls.count == 1 }
        for _ in 0..<50 { await Task.yield() }
        time += 10
        controller.turn(forward: true, isSpread: false)
        XCTAssertEqual(overlay.runs, 2)
        XCTAssertNotNil(overlay.superview, "The shared view now runs the second turn")
        await waitUntil("second show") { host.showTargetCalls.count == 2 }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(host.pendingSteps, 1, "Only the second step waits for its animation")
        overlay.finish()
        await host.drain()
        XCTAssertNil(overlay.superview)
    }

    func testStepOfInterruptedRunDoesNotWaitForTheNextRun() async {
        // The second turn comes before the first step runs: that step must not hold the queue
        // until the second animation ends.
        host.canTurnOverride = true
        controller.turn(forward: true, isSpread: false)
        controller.turn(forward: true, isSpread: false)
        XCTAssertEqual(overlay.runs, 2)
        await waitUntil("both shows while the second curl runs") {
            host.showTargetCalls.count == 2
        }
        XCTAssertNotNil(overlay.superview)
        overlay.finish()
        await host.drain()
    }
}
