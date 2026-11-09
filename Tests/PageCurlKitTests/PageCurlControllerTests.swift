import XCTest
import UIKit
@testable import PageCurlKit

/// Runs queued steps one at a time like a real pager; by default it is busy while the queue is
/// not empty.
@MainActor
private final class FakeHost: PageCurlHost {
    struct Position: Equatable {
        var value: Int
    }

    var position = Position(value: 0)
    var currentPosition: Position { position }

    var canTurnOverride: Bool?
    func canTurn() -> Bool {
        canTurnOverride ?? (pendingSteps == 0)
    }

    var paperColor: UIColor = .white

    var currentView: UIView?
    private(set) var currentViewCalls = 0
    func currentSpreadView() -> UIView? {
        currentViewCalls += 1
        return currentView
    }

    var nextView: UIView?
    var previousView: UIView?
    private(set) var neighbourCalls: [Bool] = []
    func neighbourSpreadView(forward: Bool) -> UIView? {
        neighbourCalls.append(forward)
        return forward ? nextView : previousView
    }

    /// false means the edge of the book.
    var showTargetResult: (Bool) -> Bool = { _ in true }
    private(set) var showTargetCalls: [Bool] = []
    func showTarget(forward: Bool) async -> Bool {
        showTargetCalls.append(forward)
        let shown = showTargetResult(forward)
        if shown {
            position.value += forward ? 1 : -1
        }
        return shown
    }

    private var queue: Task<Void, Never>?
    private(set) var pendingSteps = 0
    func enqueue(_ step: @escaping @MainActor () async -> Void) {
        let previous = queue
        pendingSteps += 1
        queue = Task { @MainActor [weak self] in
            await previous?.value
            await step()
            self?.pendingSteps -= 1
        }
    }

    /// A step held by a curl does not finish until the test removes the overlay.
    func drain() async {
        await queue?.value
    }
}

/// No Metal; one view for all turns, like the real one. The test finishes the animation itself.
@MainActor
private final class FakeOverlay: UIView, PageCurlOverlayAnimating {
    var onFinished: (() -> Void)?
    var failNextPrepare = false
    var failFirstFrame = false
    private(set) var requests: [PageCurlOverlayRequest] = []
    /// Started animations, that is turns that went the animated way.
    private(set) var runs = 0
    private(set) var textureReleases = 0

    func prepare(_ request: PageCurlOverlayRequest) -> Bool {
        if failNextPrepare {
            failNextPrepare = false
            return false
        }
        requests.append(request)
        return true
    }

    func startIfFirstFrameDrawn() -> Bool {
        guard !failFirstFrame else { return false }
        runs += 1
        return true
    }

    func stop() {
        onFinished = nil
    }

    func releaseTextures() {
        textureReleases += 1
    }

    func finish() {
        onFinished?()
    }
}

@MainActor
private final class FakeFactory: PageCurlOverlayFactory {
    var isAvailable = true
    let overlay = FakeOverlay()
    private(set) var makeCalls = 0

    func makeOverlay() -> PageCurlOverlayAnimating? {
        makeCalls += 1
        return isAvailable ? overlay : nil
    }
}

@MainActor
final class PageCurlControllerTests: XCTestCase {

    private let containerSize = CGSize(width: 800, height: 600)
    private var host: FakeHost!
    private var factory: FakeFactory!
    private var container: UIView!
    private var controller: PageCurlController<FakeHost>!
    private var overlay: FakeOverlay { factory.overlay }
    /// Advancing this clock ends the minimum interval between turns without waiting.
    private var time: CFTimeInterval = 1000

    override func setUp() async throws {
        try await super.setUp()
        host = FakeHost()
        factory = FakeFactory()
        container = UIView(frame: CGRect(origin: .zero, size: containerSize))
        container.backgroundColor = .systemBackground
        host.currentView = Self.spreadView(size: containerSize)
        host.nextView = Self.spreadView(size: containerSize)
        host.previousView = Self.spreadView(size: containerSize)
        controller = PageCurlController(
            host: host, container: container,
            configuration: PageCurlConfiguration(),
            overlayFactory: factory
        )
        controller.now = { [weak self] in self?.time ?? 0 }
        controller.afterFrameCommit = { work in work() }
        // Lets the size watcher record the initial size so the first layout is not seen as a resize.
        container.layoutIfNeeded()
    }

    private static func spreadView(size: CGSize) -> UIView {
        UIView(frame: CGRect(origin: .zero, size: size))
    }

    private func waitUntil(
        _ message: String, _ condition: () -> Bool
    ) async {
        for _ in 0..<2000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for: \(message)")
    }

    private func completeBeautifulTurn(forward: Bool = true) async {
        let overlaysBefore = overlay.runs
        let showsBefore = host.showTargetCalls.count
        controller.turn(forward: forward, isSpread: false)
        XCTAssertEqual(overlay.runs, overlaysBefore + 1, "Expected the beautiful path")
        await waitUntil("show under the overlay") {
            host.showTargetCalls.count == showsBefore + 1
        }
        overlay.finish()
        await host.drain()
    }

    // MARK: - Every call shows something: fallbacks go the instant way

    func testBusyHostShowsInstantly() async {
        host.canTurnOverride = false
        controller.turn(forward: true, isSpread: false)
        XCTAssertTrue(overlay.runs == 0, "A busy host means no overlay")
        await waitUntil("instant show") { host.showTargetCalls == [true] }
        await host.drain()
    }

    func testUnexpiredQuietWindowShowsInstantly() async {
        await completeBeautifulTurn()
        controller.turn(forward: true, isSpread: false)
        XCTAssertEqual(overlay.runs, 1, "No second overlay within the quiet window")
        await waitUntil("show via the instant path") { host.showTargetCalls.count == 2 }
        await host.drain()
        time += 1
        controller.turn(forward: true, isSpread: false)
        XCTAssertEqual(overlay.runs, 2)
        await waitUntil("show under the second overlay") { host.showTargetCalls.count == 3 }
        overlay.finish()
        await host.drain()
    }

    func testNoMetalShowsInstantly() async {
        factory.isAvailable = false
        controller.turn(forward: true, isSpread: false)
        XCTAssertTrue(overlay.runs == 0)
        await waitUntil("instant show") { host.showTargetCalls == [true] }
        await host.drain()
    }

    func testFailedOverlayShowsInstantly() async {
        overlay.failNextPrepare = true
        controller.turn(forward: true, isSpread: false)
        XCTAssertTrue(overlay.runs == 0)
        await waitUntil("instant show") { host.showTargetCalls == [true] }
        await host.drain()
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

    func testNilNeighbourShowsInstantly() async {
        // No neighbour (not ready or the edge): the tap still does not get swallowed.
        host.nextView = nil
        controller.turn(forward: true, isSpread: false)
        XCTAssertTrue(overlay.runs == 0)
        await waitUntil("instant show") { host.showTargetCalls == [true] }
        await host.drain()
    }

    func testNilCurrentSnapshotShowsInstantly() async {
        // A call before anything is shown: there is no current snapshot yet.
        host.currentView = nil
        controller.turn(forward: true, isSpread: false)
        XCTAssertTrue(overlay.runs == 0)
        await waitUntil("instant show") { host.showTargetCalls == [true] }
        await host.drain()
    }

    // MARK: - Only a completed show starts the minimum interval

    func testEdgeTapDoesNotArmQuietWindow() async {
        // A tap at the edge shows nothing, so it does not start the interval and the reverse tap
        // curls right away.
        host.nextView = nil
        host.showTargetResult = { forward in !forward }
        controller.turn(forward: true, isSpread: false)
        await waitUntil("the silent edge show") { host.showTargetCalls == [true] }
        await host.drain()
        XCTAssertTrue(overlay.runs == 0)

        controller.turn(forward: false, isSpread: false)
        XCTAssertEqual(overlay.runs, 1, "The silent edge tap did not arm the window — backward curls")
        await waitUntil("show backward") { host.showTargetCalls == [true, false] }
        overlay.finish()
        await host.drain()
    }

    // MARK: - Repeat call during a curl

    func testRepeatTurnInterruptsAndStillShows() async {
        controller.turn(forward: true, isSpread: false)
        let first = overlay
        XCTAssertNotNil(first.superview)
        await waitUntil("first show") { host.showTargetCalls.count == 1 }

        controller.turn(forward: true, isSpread: false)
        XCTAssertNil(first.superview, "The running curl is interrupted")
        XCTAssertEqual(overlay.runs, 1, "A repeat call goes the instant way")
        await waitUntil("second show") { host.showTargetCalls.count == 2 }
        await host.drain()
    }

    // MARK: - Cache

    func testPrefetchReusesCacheForSamePosition() async {
        controller.prefetch()
        XCTAssertEqual(host.currentViewCalls, 1)
        XCTAssertEqual(host.neighbourCalls.count, 2)
        controller.prefetch()
        XCTAssertEqual(host.currentViewCalls, 1, "A matching token and size are not re-snapshotted")
        XCTAssertEqual(host.neighbourCalls.count, 2)
    }

    func testInvalidateDropsCache() async {
        controller.prefetch()
        controller.invalidate()
        controller.prefetch()
        XCTAssertEqual(host.currentViewCalls, 2, "After invalidate the cache is rebuilt")
    }

    func testNilNeighbourIsNotCompleteness() async {
        host.nextView = nil
        controller.prefetch()
        XCTAssertEqual(host.neighbourCalls.filter { $0 }.count, 1)
        // The neighbour became ready: the next prefetch asks for the missing one again.
        host.nextView = Self.spreadView(size: containerSize)
        controller.prefetch()
        XCTAssertEqual(host.neighbourCalls.filter { $0 }.count, 2)
        controller.prefetch()
        XCTAssertEqual(host.neighbourCalls.filter { $0 }.count, 2)
    }

    func testPositionChangeRebuildsCache() async {
        controller.prefetch()
        host.position = FakeHost.Position(value: 7)
        controller.prefetch()
        XCTAssertEqual(host.currentViewCalls, 2, "A token change rebuilds the set")
    }

    func testSizeChangeRebuildsCache() async {
        controller.prefetch()
        XCTAssertEqual(host.currentViewCalls, 1)
        let newSize = CGSize(width: 600, height: 800)
        host.currentView = Self.spreadView(size: newSize)
        host.nextView = Self.spreadView(size: newSize)
        host.previousView = Self.spreadView(size: newSize)
        container.frame = CGRect(origin: .zero, size: newSize)
        container.layoutIfNeeded()
        controller.prefetch()
        XCTAssertEqual(host.currentViewCalls, 2, "A size change rebuilds the set")
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

    func testTurnShiftsCacheInsteadOfResnapshotting() async {
        controller.prefetch()
        XCTAssertEqual(host.currentViewCalls, 1)
        XCTAssertEqual(host.neighbourCalls.count, 2)
        await completeBeautifulTurn(forward: true)
        XCTAssertEqual(host.currentViewCalls, 1, "The target snapshot becomes current")
        XCTAssertEqual(host.neighbourCalls, [true, false, true], "Only the new neighbour ahead is snapshotted")
        time += 10
        await completeBeautifulTurn(forward: false)
        XCTAssertEqual(host.currentViewCalls, 1, "Turning back reuses the old current snapshot")
        XCTAssertEqual(host.neighbourCalls, [true, false, true, false])
    }

    func testTurnUsesPrefetchedCache() async {
        controller.prefetch()
        let callsAfterPrefetch = host.currentViewCalls
        controller.turn(forward: true, isSpread: false)
        XCTAssertEqual(overlay.runs, 1)
        XCTAssertEqual(host.currentViewCalls, callsAfterPrefetch, "A ready cache is not re-snapshotted on a tap")
        await waitUntil("show") { host.showTargetCalls.count == 1 }
        overlay.finish()
        await host.drain()
    }

    // MARK: - Interruption

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
        // A real host provides views at the current size, so after a resize the views are new.
        let newSize = CGSize(width: 600, height: 800)
        host.currentView = Self.spreadView(size: newSize)
        host.nextView = Self.spreadView(size: newSize)
        host.previousView = Self.spreadView(size: newSize)
        container.frame = CGRect(origin: .zero, size: newSize)
        container.layoutIfNeeded()
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

    func testBackgroundReleasesTextures() async {
        controller.warmUp()
        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        XCTAssertEqual(overlay.textureReleases, 1, "Going to the background frees the textures")
    }

    // MARK: - One view for all turns

    func testOneViewForAllTurns() async {
        controller.warmUp()
        await completeBeautifulTurn()
        time += 10
        await completeBeautifulTurn()
        XCTAssertEqual(factory.makeCalls, 1, "The view is made once and reused")
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

    // MARK: - Paper color

    func testOverlayTakesPaperColorFromHost() async {
        host.paperColor = .black
        container.backgroundColor = .white
        controller.turn(forward: true, isSpread: false)
        XCTAssertEqual(overlay.requests[0].paperColor, .black)
        await waitUntil("show") { host.showTargetCalls.count == 1 }
        overlay.finish()
        await host.drain()
    }
}
