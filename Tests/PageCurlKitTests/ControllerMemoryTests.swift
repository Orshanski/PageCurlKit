import XCTest
import UIKit
@testable import PageCurlKit

/// The controller lets go of its snapshots when the app leaves or runs short of memory.
@MainActor
final class ControllerMemoryTests: ControllerTestCase {

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    func testBackgroundDropsSnapshots() async {
        controller.prefetch()
        XCTAssertEqual(host.currentViewCalls, 1)
        post(UIApplication.didEnterBackgroundNotification)
        post(UIApplication.willEnterForegroundNotification)
        controller.prefetch()
        XCTAssertEqual(host.currentViewCalls, 2, "The spread on screen is snapshotted again after the return")
    }

    func testBackgroundMidCurlDoesNotRebuildSnapshots() async {
        var pendingWork: [@MainActor () -> Void] = []
        controller.afterFrameCommit = { pendingWork.append($0) }
        controller.turn(forward: true, isSpread: false)
        await waitUntil("show") { host.showTargetCalls.count == 1 }
        let currentCalls = host.currentViewCalls
        let neighbourCalls = host.neighbourCalls

        post(UIApplication.didEnterBackgroundNotification)
        pendingWork.forEach { $0() }
        XCTAssertEqual(host.currentViewCalls, currentCalls, "No snapshots are built in the background")
        XCTAssertEqual(host.neighbourCalls, neighbourCalls, "No snapshots are built in the background")
        await host.drain()
    }

    func testPrefetchInBackgroundBuildsNothing() async {
        post(UIApplication.didEnterBackgroundNotification)
        controller.prefetch()
        XCTAssertEqual(host.currentViewCalls, 0)
        XCTAssertEqual(host.neighbourCalls, [])
        post(UIApplication.willEnterForegroundNotification)
    }

    func testReturnFromBackgroundPrefetches() async {
        post(UIApplication.didEnterBackgroundNotification)
        post(UIApplication.willEnterForegroundNotification)
        XCTAssertEqual(host.currentViewCalls, 1, "Snapshots are ready without a call from the host")
        XCTAssertEqual(host.neighbourCalls, [true, false])
    }

    func testMemoryWarningDropsSnapshotsAndKeepsTheCurl() async {
        controller.prefetch()
        XCTAssertEqual(host.currentViewCalls, 1)
        controller.turn(forward: true, isSpread: false)
        await waitUntil("show") { host.showTargetCalls.count == 1 }

        post(UIApplication.didReceiveMemoryWarningNotification)
        XCTAssertNotNil(overlay.superview, "A memory warning does not interrupt the curl")
        XCTAssertEqual(overlay.textureReleases, 0, "A memory warning leaves the textures of the curl alone")

        overlay.finish()
        await host.drain()
        XCTAssertEqual(host.currentViewCalls, 2, "The snapshots were dropped, so the spread on screen is snapshotted again")
    }
}
