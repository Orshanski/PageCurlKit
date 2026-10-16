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

/// No Metal; the test finishes the animation itself.
@MainActor
private final class FakeOverlay: UIView, PageCurlOverlayAnimating {
    var onFinished: (() -> Void)?
    private(set) var started = false

    func start() {
        started = true
    }

    func finish() {
        onFinished?()
    }
}

@MainActor
private final class FakeFactory: PageCurlOverlayFactory {
    var isAvailable = true
    var failNextMake = false
    private(set) var made: [FakeOverlay] = []
    private(set) var requests: [PageCurlOverlayRequest] = []
    private(set) var warmUpCalls = 0

    func warmUp() {
        warmUpCalls += 1
    }

    func makeOverlay(_ request: PageCurlOverlayRequest) -> PageCurlOverlayAnimating? {
        if failNextMake {
            failNextMake = false
            return nil
        }
        requests.append(request)
        let overlay = FakeOverlay()
        made.append(overlay)
        return overlay
    }
}

@MainActor
final class PageCurlControllerTests: XCTestCase {

    private let containerSize = CGSize(width: 800, height: 600)
    private var host: FakeHost!
    private var factory: FakeFactory!
    private var container: UIView!
    private var controller: PageCurlController<FakeHost>!
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
        let overlaysBefore = factory.made.count
        let showsBefore = host.showTargetCalls.count
        controller.turn(forward: forward, isSpread: false)
        XCTAssertEqual(factory.made.count, overlaysBefore + 1, "Expected the beautiful path")
        await waitUntil("show under the overlay") {
            host.showTargetCalls.count == showsBefore + 1
        }
        factory.made.last?.finish()
        await host.drain()
    }

    // MARK: - Every call shows something: fallbacks go the instant way

    func testBusyHostShowsInstantly() async {
        host.canTurnOverride = false
        controller.turn(forward: true, isSpread: false)
        XCTAssertTrue(factory.made.isEmpty, "A busy host means no overlay")
        await waitUntil("instant show") { host.showTargetCalls == [true] }
        await host.drain()
    }

    func testUnexpiredQuietWindowShowsInstantly() async {
        await completeBeautifulTurn()
        controller.turn(forward: true, isSpread: false)
        XCTAssertEqual(factory.made.count, 1, "No second overlay within the quiet window")
        await waitUntil("show via the instant path") { host.showTargetCalls.count == 2 }
        await host.drain()
        time += 1
        controller.turn(forward: true, isSpread: false)
        XCTAssertEqual(factory.made.count, 2)
        await waitUntil("show under the second overlay") { host.showTargetCalls.count == 3 }
        factory.made.last?.finish()
        await host.drain()
    }

    func testNoMetalShowsInstantly() async {
        factory.isAvailable = false
        controller.turn(forward: true, isSpread: false)
        XCTAssertTrue(factory.made.isEmpty)
        await waitUntil("instant show") { host.showTargetCalls == [true] }
        await host.drain()
    }

    func testFailedOverlayShowsInstantly() async {
        factory.failNextMake = true
        controller.turn(forward: true, isSpread: false)
        XCTAssertTrue(factory.made.isEmpty)
        await waitUntil("instant show") { host.showTargetCalls == [true] }
        await host.drain()
    }

    func testEmptyCacheAssembledOnTheSpot() async {
        // Without any prefetch a tap still gets the animated path.
        controller.turn(forward: true, isSpread: false)
        XCTAssertEqual(factory.made.count, 1)
        XCTAssertEqual(host.currentViewCalls, 1)
        XCTAssertEqual(host.neighbourCalls, [true], "On-the-spot assembly takes only the needed direction")
        await waitUntil("show under the overlay") { host.showTargetCalls == [true] }
        factory.made[0].finish()
        await host.drain()
    }

    func testNilNeighbourShowsInstantly() async {
        // No neighbour (not ready or the edge): the tap still does not get swallowed.
        host.nextView = nil
        controller.turn(forward: true, isSpread: false)
        XCTAssertTrue(factory.made.isEmpty)
        await waitUntil("instant show") { host.showTargetCalls == [true] }
        await host.drain()
    }

    func testNilCurrentSnapshotShowsInstantly() async {
        // A call before anything is shown: there is no current snapshot yet.
        host.currentView = nil
        controller.turn(forward: true, isSpread: false)
        XCTAssertTrue(factory.made.isEmpty)
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
        XCTAssertTrue(factory.made.isEmpty)

        controller.turn(forward: false, isSpread: false)
        XCTAssertEqual(factory.made.count, 1, "The silent edge tap did not arm the window — backward curls")
        await waitUntil("show backward") { host.showTargetCalls == [true, false] }
        factory.made[0].finish()
        await host.drain()
    }

    // MARK: - Repeat call during a curl

    func testRepeatTurnInterruptsAndStillShows() async {
        controller.turn(forward: true, isSpread: false)
        let first = factory.made[0]
        XCTAssertNotNil(first.superview)
        await waitUntil("first show") { host.showTargetCalls.count == 1 }

        controller.turn(forward: true, isSpread: false)
        XCTAssertNil(first.superview, "The running curl is interrupted")
        XCTAssertEqual(factory.made.count, 1, "A repeat call goes the instant way")
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
        factory.made[0].finish()
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
        XCTAssertEqual(factory.made.count, 1)
        XCTAssertEqual(host.currentViewCalls, callsAfterPrefetch, "A ready cache is not re-snapshotted on a tap")
        await waitUntil("show") { host.showTargetCalls.count == 1 }
        factory.made[0].finish()
        await host.drain()
    }

    // MARK: - Interruption

    func testInterruptIsIdempotent() async {
        controller.interrupt()
        controller.interrupt()

        controller.turn(forward: true, isSpread: false)
        let overlay = factory.made[0]
        await waitUntil("show") { host.showTargetCalls.count == 1 }
        controller.interrupt()
        XCTAssertNil(overlay.superview)
        controller.interrupt()
        await host.drain()
    }

    func testBackgroundNotificationInterrupts() async {
        controller.turn(forward: true, isSpread: false)
        let overlay = factory.made[0]
        await waitUntil("show") { host.showTargetCalls.count == 1 }
        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        XCTAssertNil(overlay.superview, "Backgrounding interrupts the curl")
        await host.drain()
    }

    func testContainerResizeInterrupts() async {
        controller.turn(forward: true, isSpread: false)
        let overlay = factory.made[0]
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

    // MARK: - Paper color

    func testOverlayTakesPaperColorFromHost() async {
        host.paperColor = .black
        container.backgroundColor = .white
        controller.turn(forward: true, isSpread: false)
        XCTAssertEqual(factory.requests[0].paperColor, .black)
        await waitUntil("show") { host.showTargetCalls.count == 1 }
        factory.made[0].finish()
        await host.drain()
    }
}
