import UIKit

/// The pager that owns the content: text, PDF, static images, anything. The library knows nothing
/// about pages or sections: a position is an opaque token, and providing neighbours and showing
/// them is up to the host.
@MainActor
public protocol PageCurlHost: AnyObject {
    /// Identifies the spread currently on screen; used as the snapshot cache key. Only equality
    /// matters to the library.
    associatedtype Position: Equatable

    var currentPosition: Position { get }

    /// Return false while the host is busy (for a pager with a queue: the queue is not empty);
    /// the turn then happens instantly, without the animation.
    func canTurn() -> Bool

    /// Fills transparent areas of the snapshots and colors the back of a single page.
    var paperColor: UIColor { get }

    /// The spread on screen, sized to the container. Return nil if nothing is shown yet.
    func currentSpreadView() -> UIView?

    /// The neighbouring spread, sized to the container; it does not need to be on screen. If a view
    /// controller lays it out, keep that controller alive until the next call. Return nil at the
    /// edge of the book or if it is not ready yet; in the latter case start preparing it and call
    /// `prefetch()` on the controller when it is ready.
    func neighbourSpreadView(forward: Bool) -> UIView?

    /// Show the target spread instantly and return once it is on screen. Return false if there is
    /// nothing to show.
    func showTarget(forward: Bool) async -> Bool

    /// Add a step to the host's transition queue. Steps must run one at a time, each starting after
    /// the previous one finishes; a host without a queue may run the step right away.
    func enqueue(_ step: @escaping @MainActor () async -> Void)
}
