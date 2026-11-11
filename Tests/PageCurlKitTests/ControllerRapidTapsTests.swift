import XCTest
import UIKit
@testable import PageCurlKit

/// Rapid taps only show pages; the snapshots wait until the taps stop and are taken one at a time.
@MainActor
final class ControllerRapidTapsTests: ControllerTestCase {

    /// Run loop passes the controller asked for, run by the test one at a time.
    private var pendingPasses: [@MainActor () -> Void] = []

    private func holdPasses() {
        pendingPasses = []
        controller.onNextPass = { [weak self] work in self?.pendingPasses.append(work) }
    }

    private func runNextPass() {
        guard !pendingPasses.isEmpty else { return XCTFail("No pass was asked for") }
        pendingPasses.removeFirst()()
    }

    /// A tap within the quiet window, followed by the host's prefetch() after the show.
    private func rapidTap(forward: Bool) async {
        let shows = host.showTargetCalls.count
        controller.turn(forward: forward, isSpread: false)
        await waitUntil("instant show") { host.showTargetCalls.count == shows + 1 }
        await host.drain()
        controller.prefetch()
    }

    private func endSeries() {
        time += controller.configuration.duration
        let work = delayedWork
        delayedWork = []
        work.forEach { $0.work() }
    }

    func testRapidTapsTakeNoSnapshots() async {
        controller.prefetch()
        await completeBeautifulTurn()
        let loads = overlay.loads
        let currentCalls = host.currentViewCalls
        let neighbourCalls = host.neighbourCalls

        for _ in 0..<3 {
            await rapidTap(forward: true)
        }
        XCTAssertEqual(overlay.runs, 1, "Rapid taps do not curl")
        XCTAssertEqual(host.showTargetCalls.count, 4, "Every rapid tap shows a page")
        XCTAssertEqual(overlay.loads, loads, "No snapshot during rapid tapping")
        XCTAssertEqual(host.currentViewCalls, currentCalls)
        XCTAssertEqual(host.neighbourCalls, neighbourCalls)
    }

    func testCaptureStartsAfterTheTapsStopAndTakesOneSnapshotPerPass() async {
        controller.prefetch()
        await completeBeautifulTurn(forward: false)
        holdPasses()
        await rapidTap(forward: false)
        await rapidTap(forward: false)
        XCTAssertEqual(delayedWork.last?.delay, controller.configuration.duration)
        let loads = overlay.loads
        let currentCalls = host.currentViewCalls
        let neighbourCalls = host.neighbourCalls

        endSeries()
        XCTAssertEqual(overlay.loads, loads + 1, "Only the spread on screen in the first pass")
        XCTAssertEqual(host.currentViewCalls, currentCalls + 1)
        XCTAssertEqual(host.neighbourCalls, neighbourCalls)

        runNextPass()
        XCTAssertEqual(overlay.loads, loads + 2)
        XCTAssertEqual(host.neighbourCalls, neighbourCalls + [false], "The neighbour in the tapping direction first")

        runNextPass()
        XCTAssertEqual(overlay.loads, loads + 3)
        XCTAssertEqual(host.neighbourCalls, neighbourCalls + [false, true])

        runNextPass()
        XCTAssertTrue(pendingPasses.isEmpty, "Nothing is left to take")
        XCTAssertEqual(overlay.loads, loads + 3)
    }

    func testTapStopsTheRestOfTheCapture() async {
        controller.prefetch()
        await completeBeautifulTurn()
        holdPasses()
        await rapidTap(forward: true)
        await rapidTap(forward: true)
        endSeries()
        XCTAssertEqual(pendingPasses.count, 1, "The spread on screen is taken, the neighbours wait")

        time += 10
        controller.turn(forward: true, isSpread: false)
        XCTAssertEqual(overlay.runs, 2, "A tap after a pause curls")
        let neighbourCalls = host.neighbourCalls
        let loads = overlay.loads
        runNextPass()
        XCTAssertTrue(pendingPasses.isEmpty, "The capture stopped")
        XCTAssertEqual(host.neighbourCalls, neighbourCalls, "No snapshot after the tap")
        XCTAssertEqual(overlay.loads, loads)

        await waitUntil("show under the overlay") { host.showTargetCalls.count == 4 }
        overlay.finish()
        await host.drain()
    }

    func testTapAfterTheCaptureCurlsWithReadySnapshots() async {
        controller.prefetch()
        await completeBeautifulTurn()
        await rapidTap(forward: true)
        await rapidTap(forward: true)
        endSeries()
        let loads = overlay.loads

        time += 10
        controller.turn(forward: true, isSpread: false)
        XCTAssertEqual(overlay.runs, 2, "A single tap after the pause curls")
        XCTAssertEqual(overlay.loads, loads, "The snapshots were ready")
        await waitUntil("show under the overlay") { host.showTargetCalls.count == 4 }
        overlay.finish()
        await host.drain()
    }
}
