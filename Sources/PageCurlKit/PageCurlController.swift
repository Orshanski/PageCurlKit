import UIKit

/// What drives the curl progress. `.gesture` is not implemented yet: debug builds assert, release
/// builds turn instantly.
public enum PageCurlProgressSource: Equatable {
    case timed
    case gesture
}

/// Route every page turn through this controller. Each call results in a transition, animated or
/// instant; nothing happens only at the edge of the book.
@MainActor
public final class PageCurlController<Host: PageCurlHost> {

    public var configuration: PageCurlConfiguration

    private weak var host: Host?
    private weak var container: UIView?
    private let overlayFactory: PageCurlOverlayFactory
    /// The curl view for every turn, asked from the factory until it gives one.
    private var overlay: PageCurlOverlayAnimating?
    /// The running curl, if any. A queued step of an earlier run sees a different number and leaves
    /// the current run alone.
    private var activeRun: Int?
    private var runNumber = 0
    /// Holds the host's queue step until the animation ends; an interruption releases it at once.
    private var holdContinuation: CheckedContinuation<Void, Never>?
    /// Set only after a confirmed show, so a tap at the edge of the book does not block the next turn.
    private var lastShownAt: CFTimeInterval = 0

    // Tests replace the clock and the wait for the frame commit.
    var now: () -> CFTimeInterval = { CACurrentMediaTime() }
    var afterFrameCommit: (@escaping @MainActor () -> Void) -> Void = { work in
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated(work)
        }
    }

    private var cache: SnapshotCache<Host.Position, UIImage>?

    private let sizeSentinel = ContainerSizeSentinel()
    private var appWatcher: AppNotificationWatcher?
    /// Snapshots built in the background would stay in memory the whole time the app is away.
    private var isInBackground = false

    public convenience init(
        host: Host, container: UIView,
        configuration: PageCurlConfiguration = PageCurlConfiguration()
    ) {
        self.init(
            host: host, container: container, configuration: configuration,
            overlayFactory: MetalOverlayFactory()
        )
    }

    init(
        host: Host, container: UIView, configuration: PageCurlConfiguration,
        overlayFactory: PageCurlOverlayFactory
    ) {
        self.host = host
        self.container = container
        self.configuration = configuration
        self.overlayFactory = overlayFactory
        sizeSentinel.frame = container.bounds
        sizeSentinel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sizeSentinel.onSizeChange = { [weak self] in self?.interrupt(reason: "container resized") }
        container.insertSubview(sizeSentinel, at: 0)
        appWatcher = AppNotificationWatcher([
            UIApplication.didEnterBackgroundNotification: { [weak self] in self?.enterBackground() },
            UIApplication.willEnterForegroundNotification: { [weak self] in self?.enterForeground() },
            // A running curl already holds its textures, so dropping the snapshots does not stop it.
            UIApplication.didReceiveMemoryWarningNotification: { [weak self] in self?.cache = nil },
        ])
    }

    private func enterBackground() {
        // Set first: the interruption schedules a rebuild that runs after this handler.
        isInBackground = true
        interrupt(reason: "app went to the background")
        overlay?.releaseTextures()
        cache = nil
    }

    private func enterForeground() {
        isInBackground = false
        prefetch()
    }

    deinit {
        // If the controller dies mid-curl, the held queue step must still finish.
        holdContinuation?.resume()
    }

    /// Creates the curl view and compiles its shaders ahead of time. Call it when the pager opens;
    /// otherwise the first curl drops frames.
    public func warmUp() {
        _ = curlView()
    }

    private func curlView() -> PageCurlOverlayAnimating? {
        if overlay == nil {
            overlay = overlayFactory.makeOverlay()
        }
        return overlay
    }

    public func turn(
        forward: Bool, isSpread: Bool,
        progress: PageCurlProgressSource = .timed
    ) {
        let touchedAt = CACurrentMediaTime()
        // A call during a running curl cancels it and then proceeds as usual.
        interrupt(reason: "a new turn")
        guard let host, let container else { return }
        if progress == .gesture {
            assertionFailure("Finger tracking is not implemented: .gesture is a stub")
            return enqueueInstantShow(forward: forward, host: host, reason: "finger tracking is a stub")
        }
        // These checks run before anything is enqueued; that is what lets the host treat an empty
        // queue as "not busy".
        let size = container.bounds.size
        guard host.canTurn() else {
            return enqueueInstantShow(forward: forward, host: host, reason: "host is busy", isFailure: false)
        }
        guard now() - lastShownAt > configuration.duration else {
            return enqueueInstantShow(forward: forward, host: host, reason: "previous turn too recent", isFailure: false)
        }
        guard let overlay = curlView() else {
            return enqueueInstantShow(forward: forward, host: host, reason: "no curl view")
        }
        guard size.width > 0, size.height > 0 else {
            return enqueueInstantShow(forward: forward, host: host, reason: "empty container")
        }
        guard let pair = snapshotPair(forward: forward, host: host, size: size) else {
            return enqueueInstantShow(forward: forward, host: host, reason: "no snapshots")
        }
        guard overlay.prepare(PageCurlOverlayRequest(
            currentSpread: pair.current,
            targetSpread: pair.target,
            sizePoints: size,
            forward: forward,
            isSpread: isSpread,
            paperColor: host.paperColor,
            configuration: configuration
        )) else {
            return enqueueInstantShow(forward: forward, host: host, reason: "overlay not prepared")
        }

        runNumber += 1
        let run = runNumber
        container.addSubview(overlay)
        activeRun = run
        overlay.onFinished = { [weak self] in self?.release() }
        curlLog.debug("turn \(run) started: forward \(forward), spread \(isSpread)")
        guard overlay.startIfFirstFrameDrawn() else {
            stopRun()
            return enqueueInstantShow(forward: forward, host: host, reason: "first frame not drawn")
        }
        let milliseconds = (CACurrentMediaTime() - touchedAt) * 1000
        curlLog.notice("turn \(run): first frame \(milliseconds, format: .fixed(precision: 1)) ms after the touch")

        // Weak captures only: the step waits until the animation ends, and a strong reference
        // would keep a closed host and the Metal textures alive if it is dismissed mid-curl.
        host.enqueue { [weak self, weak host] in
            guard let host else { return }
            let shown = await Self.show(forward: forward, host: host) { [weak self] in self }
            if !shown {
                // The host provided a neighbour view but then could not show it: an integration bug.
                assertionFailure("showTarget did not show the spread the host provided a view for")
                if let self, self.activeRun == run {
                    self.interrupt(reason: "showTarget showed nothing", isFailure: true)
                }
                return
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard let self, self.activeRun == run else {
                    continuation.resume()
                    return
                }
                self.holdContinuation = continuation
            }
        }
    }

    /// Call after each show and when a neighbour that was not ready becomes ready; otherwise each
    /// turn snapshots the spreads on the spot.
    public func prefetch() {
        // During a curl the main thread is busy with frames; release() restarts the rebuild.
        guard activeRun == nil else { return }
        // After the frame commits: rebuilding in the same run loop pass would stall the first
        // frames of the animation.
        afterFrameCommit { [weak self] in
            self?.rebuildCache()
        }
    }

    /// Drops the cache when the content changed without a position change, for example after
    /// relayout or a theme change.
    public func invalidate() {
        cache = nil
    }

    /// Stops a running curl. Call it when something makes the animation stale, for example a show
    /// that bypasses the controller or an opened menu.
    public func interrupt() {
        interrupt(reason: "host interrupted")
    }

    private func interrupt(reason: String, isFailure: Bool = false) {
        guard let activeRun else { return }
        if isFailure {
            curlLog.error("turn \(activeRun) interrupted: \(reason, privacy: .public)")
        } else {
            curlLog.debug("turn \(activeRun) interrupted: \(reason, privacy: .public)")
        }
        release()
    }

    private func release() {
        stopRun()
        holdContinuation?.resume()
        holdContinuation = nil
        prefetch()
    }

    private func stopRun() {
        overlay?.stop()
        overlay?.removeFromSuperview()
        activeRun = nil
    }

    /// `isFailure` false — an expected fallback (busy host, rapid tapping), logged at debug level.
    private func enqueueInstantShow(forward: Bool, host: Host, reason: String, isFailure: Bool = true) {
        if isFailure {
            curlLog.error("instant show: \(reason, privacy: .public)")
        } else {
            curlLog.debug("instant show: \(reason, privacy: .public)")
        }
        host.enqueue { [weak self, weak host] in
            guard let host else { return }
            _ = await Self.show(forward: forward, host: host) { [weak self] in self }
        }
    }

    /// Shows the target; after a show starts the quiet window and moves the cache along. The show
    /// happens even if the controller is gone: it is looked up only after the show, so the wait does
    /// not keep it alive.
    private static func show(
        forward: Bool, host: Host, controller: () -> PageCurlController?
    ) async -> Bool {
        let from = host.currentPosition
        let shown = await host.showTarget(forward: forward)
        if shown, let controller = controller() {
            controller.lastShownAt = controller.now()
            if let shifted = controller.cache?.shifted(
                forward: forward, from: from, to: host.currentPosition
            ) {
                controller.cache = shifted
            }
        }
        return shown
    }

    private func snapshotPair(
        forward: Bool, host: Host, size: CGSize
    ) -> (current: UIImage, target: UIImage)? {
        fillCache(host: host, size: size, directions: [forward])
        return cache?.pair(forward: forward)
    }

    private func rebuildCache() {
        guard activeRun == nil, !isInBackground, let host, let container else { return }
        let size = container.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        fillCache(host: host, size: size, directions: [true, false])
    }

    /// Snapshots what the cache lacks: the spread on screen if the cache is for another position or
    /// size, and the missing neighbours in `directions` (true — ahead).
    private func fillCache(host: Host, size: CGSize, directions: [Bool]) {
        let position = host.currentPosition
        if cache?.isValid(for: position, size: size) != true {
            guard let view = host.currentSpreadView() else {
                cache = nil
                return
            }
            cache = SnapshotCache(
                position: position, size: size,
                current: snapshot(of: view, size: size, paper: host.paperColor)
            )
        }
        for forward in directions where cache?.neighbour(forward: forward) == nil {
            let image = host.neighbourSpreadView(forward: forward)
                .map { snapshot(of: $0, size: size, paper: host.paperColor) }
            cache?.setNeighbour(image, forward: forward)
        }
    }

    /// The Metal view is opaque, so transparent pixels would turn black; paper is drawn underneath.
    private func snapshot(of view: UIView, size: CGSize, paper: UIColor) -> UIImage {
        assert(view.bounds.size == size, "The host spread view must match the container size")
        view.layoutIfNeeded()
        return UIGraphicsImageRenderer(size: size, format: SnapshotRaster.rendererFormat()).image { context in
            paper.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            view.layer.render(in: context.cgContext)
        }
    }
}

private final class AppNotificationWatcher {
    private let tokens: [NSObjectProtocol]

    init(_ handlers: [Notification.Name: @MainActor () -> Void]) {
        tokens = handlers.map { name, handler in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            }
        }
    }

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }
}

/// A hidden subview of the container that reports size changes from its own layout.
@MainActor
private final class ContainerSizeSentinel: UIView {
    var onSizeChange: (() -> Void)?
    private var lastSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize else { return }
        let firstLayout = lastSize == .zero
        lastSize = bounds.size
        if !firstLayout {
            onSizeChange?()
        }
    }
}
