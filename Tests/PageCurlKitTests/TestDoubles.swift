import XCTest
import UIKit
@testable import PageCurlKit

/// Runs queued steps one at a time like a real pager; by default it is busy while the queue is
/// not empty.
@MainActor
final class FakeHost: PageCurlHost {
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

final class FakeSnapshot: LoadedSnapshot {}

/// No Metal; one view for all turns, like the real one. The test finishes the animation itself.
@MainActor
final class FakeOverlay: UIView, PageCurlOverlayAnimating {
    var onFinished: (() -> Void)?
    var failNextPrepare = false
    var failFirstFrame = false
    /// How many more snapshots load before loading starts to fail; nil — never fails.
    var successfulLoadsLeft: Int?
    private(set) var loads = 0
    private(set) var requests: [PageCurlOverlayRequest] = []
    /// Started animations, that is turns that went the animated way.
    private(set) var runs = 0
    private(set) var textureReleases = 0

    func load(_ snapshot: UIImage) -> LoadedSnapshot? {
        if let left = successfulLoadsLeft {
            guard left > 0 else { return nil }
            successfulLoadsLeft = left - 1
        }
        loads += 1
        return FakeSnapshot()
    }

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
final class FakeFactory: PageCurlOverlayFactory {
    var isAvailable = true
    let overlay = FakeOverlay()
    private(set) var makeCalls = 0

    func makeOverlay() -> PageCurlOverlayAnimating? {
        makeCalls += 1
        return isAvailable ? overlay : nil
    }
}

/// A controller over the fakes, with a clock the test moves by hand.
@MainActor
class ControllerTestCase: XCTestCase {

    let containerSize = CGSize(width: 800, height: 600)
    var host: FakeHost!
    var factory: FakeFactory!
    var container: UIView!
    var controller: PageCurlController<FakeHost>!
    var overlay: FakeOverlay { factory.overlay }
    /// Advancing this clock ends the minimum interval between turns without waiting.
    var time: CFTimeInterval = 1000

    override func setUp() async throws {
        try await super.setUp()
        makeFixture()
    }

    func makeFixture() {
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

    static func spreadView(size: CGSize) -> UIView {
        UIView(frame: CGRect(origin: .zero, size: size))
    }

    /// A real host provides views at the current size, so after a resize the views are new.
    func resizeContainer(to size: CGSize) {
        host.currentView = Self.spreadView(size: size)
        host.nextView = Self.spreadView(size: size)
        host.previousView = Self.spreadView(size: size)
        container.frame = CGRect(origin: .zero, size: size)
        container.layoutIfNeeded()
    }

    // The async helpers stay out of Objective-C, where they could not take a non-escaping closure.
    @nonobjc final func waitUntil(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<2000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for: \(message)")
    }

    @nonobjc func completeBeautifulTurn(forward: Bool = true, isSpread: Bool = false) async {
        let runsBefore = overlay.runs
        let showsBefore = host.showTargetCalls.count
        controller.turn(forward: forward, isSpread: isSpread)
        XCTAssertEqual(overlay.runs, runsBefore + 1, "Expected the beautiful path")
        await waitUntil("show under the overlay") {
            host.showTargetCalls.count == showsBefore + 1
        }
        overlay.finish()
        await host.drain()
    }
}
