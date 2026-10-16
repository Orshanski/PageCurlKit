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
    private var overlay: PageCurlOverlayAnimating?
    /// Holds the host's queue step until the animation ends; an interruption releases it at once.
    private var holdContinuation: CheckedContinuation<Void, Never>?
    /// Set only after a confirmed show, so a tap at the edge of the book does not block the next turn.
    private var lastShownAt: CFTimeInterval = 0

    // Test seams.
    var now: () -> CFTimeInterval = { CACurrentMediaTime() }
    var afterFrameCommit: (@escaping @MainActor () -> Void) -> Void = { work in
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated(work)
        }
    }

    private struct SnapshotCache {
        let position: Host.Position
        let size: CGSize
        let current: UIImage
        var next: UIImage?
        var previous: UIImage?
    }
    private var cache: SnapshotCache?

    private let sizeSentinel = ContainerSizeSentinel()
    private var backgroundWatcher: BackgroundWatcher?

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
        sizeSentinel.onSizeChange = { [weak self] in self?.interrupt() }
        container.insertSubview(sizeSentinel, at: 0)
        backgroundWatcher = BackgroundWatcher { [weak self] in self?.interrupt() }
    }

    deinit {
        // If the controller dies mid-curl, the held queue step must still finish.
        holdContinuation?.resume()
    }

    /// Compiles the shaders ahead of time. Call it when the pager opens; otherwise the first curl
    /// drops frames.
    public func warmUp() {
        overlayFactory.warmUp()
    }

    public func turn(
        forward: Bool, isSpread: Bool,
        progress: PageCurlProgressSource = .timed
    ) {
        // A call during a running curl cancels it and then proceeds as usual.
        if overlay != nil {
            release()
        }
        guard let host, let container else { return }
        if progress == .gesture {
            assertionFailure("Finger tracking is not implemented: .gesture is a stub")
            enqueueInstantShow(forward: forward, host: host)
            return
        }
        // These checks run before anything is enqueued; that is what lets the host treat an empty
        // queue as "not busy".
        let size = container.bounds.size
        guard host.canTurn(),
              now() - lastShownAt > configuration.duration,
              overlayFactory.isAvailable,
              size.width > 0, size.height > 0,
              let pair = snapshotPair(forward: forward, host: host, size: size),
              let overlay = overlayFactory.makeOverlay(PageCurlOverlayRequest(
                  currentSpread: pair.current,
                  targetSpread: pair.target,
                  sizePoints: size,
                  forward: forward,
                  isSpread: isSpread,
                  paperColor: host.paperColor,
                  configuration: configuration
              ))
        else {
            enqueueInstantShow(forward: forward, host: host)
            return
        }

        overlay.frame = container.bounds
        container.addSubview(overlay)
        self.overlay = overlay
        overlay.onFinished = { [weak self] in self?.release() }
        overlay.start()

        // Weak captures only: the step waits until the animation ends, and a strong reference
        // would keep a closed host and the Metal textures alive if it is dismissed mid-curl.
        host.enqueue { [weak self, weak host] in
            guard let host else { return }
            let from = host.currentPosition
            let shown = await host.showTarget(forward: forward)
            if shown {
                if let self {
                    self.lastShownAt = self.now()
                    self.shiftCache(forward: forward, from: from, to: host.currentPosition)
                }
            } else {
                // The host provided a neighbour view but then could not show it: an integration bug.
                assertionFailure("showTarget did not show the spread the host provided a view for")
                self?.release()
                return
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard let self, self.overlay != nil else {
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
        guard overlay == nil else { return }
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
        guard overlay != nil else { return }
        release()
    }

    private func release() {
        overlay?.removeFromSuperview()
        overlay = nil
        holdContinuation?.resume()
        holdContinuation = nil
        prefetch()
    }

    private func enqueueInstantShow(forward: Bool, host: Host) {
        host.enqueue { [weak self, weak host] in
            guard let host else { return }
            let from = host.currentPosition
            let shown = await host.showTarget(forward: forward)
            if shown, let self {
                self.lastShownAt = self.now()
                self.shiftCache(forward: forward, from: from, to: host.currentPosition)
            }
        }
    }

    /// After a one-step turn the target snapshot becomes current and the old current becomes the
    /// neighbour behind, so only the new neighbour ahead is snapshotted.
    private func shiftCache(forward: Bool, from: Host.Position, to: Host.Position) {
        guard from != to, let old = cache, old.position == from,
              let target = forward ? old.next : old.previous
        else { return }
        cache = SnapshotCache(
            position: to, size: old.size, current: target,
            next: forward ? nil : old.current,
            previous: forward ? old.current : nil
        )
    }

    private func snapshotPair(
        forward: Bool, host: Host, size: CGSize
    ) -> (current: UIImage, target: UIImage)? {
        fillCache(host: host, size: size, next: forward, previous: !forward)
        guard let cache, let target = forward ? cache.next : cache.previous else { return nil }
        return (cache.current, target)
    }

    private func rebuildCache() {
        guard overlay == nil, let host, let container else { return }
        let size = container.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        fillCache(host: host, size: size, next: true, previous: true)
    }

    /// A missing neighbour is not cached as missing: it is requested again next time.
    private func fillCache(host: Host, size: CGSize, next: Bool, previous: Bool) {
        let position = host.currentPosition
        if cache?.position != position || cache?.size != size {
            guard let view = host.currentSpreadView() else {
                cache = nil
                return
            }
            cache = SnapshotCache(
                position: position, size: size,
                current: snapshot(of: view, size: size, paper: host.paperColor),
                next: nil, previous: nil
            )
        }
        if next, cache?.next == nil {
            cache?.next = host.neighbourSpreadView(forward: true)
                .map { snapshot(of: $0, size: size, paper: host.paperColor) }
        }
        if previous, cache?.previous == nil {
            cache?.previous = host.neighbourSpreadView(forward: false)
                .map { snapshot(of: $0, size: size, paper: host.paperColor) }
        }
    }

    /// The Metal view is opaque, so transparent pixels would turn black; paper is drawn underneath.
    private func snapshot(of view: UIView, size: CGSize, paper: UIColor) -> UIImage {
        assert(view.bounds.size == size, "The host spread view must match the container size")
        view.layoutIfNeeded()
        // 8 bits per channel, what the render expects; a wide-color display would otherwise give 16.
        let format = UIGraphicsImageRendererFormat.preferred()
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            paper.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            view.layer.render(in: context.cgContext)
        }
    }
}

private final class BackgroundWatcher {
    private let token: NSObjectProtocol

    init(onBackground: @escaping @MainActor () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onBackground() }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
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
