import CoreGraphics

/// Snapshots of the spread on screen and its neighbours, taken at one position and size.
struct SnapshotCache<Position: Equatable, Image> {
    let position: Position
    let size: CGSize
    let current: Image
    private(set) var next: Image?
    private(set) var previous: Image?

    init(position: Position, size: CGSize, current: Image, next: Image? = nil, previous: Image? = nil) {
        self.position = position
        self.size = size
        self.current = current
        self.next = next
        self.previous = previous
    }

    func isValid(for position: Position, size: CGSize) -> Bool {
        self.position == position && self.size == size
    }

    func neighbour(forward: Bool) -> Image? {
        forward ? next : previous
    }

    /// A missing neighbour is not remembered as missing: it is asked for again next time.
    mutating func setNeighbour(_ image: Image?, forward: Bool) {
        if forward {
            next = image
        } else {
            previous = image
        }
    }

    /// What the curl needs for a turn: the spread on screen and the one it turns to.
    func pair(forward: Bool) -> (current: Image, target: Image)? {
        neighbour(forward: forward).map { (current, $0) }
    }

    /// After a one-step turn the target becomes current and the old current becomes the neighbour
    /// behind; the neighbour ahead is unknown. Nil when the cache does not describe that turn.
    func shifted(forward: Bool, from: Position, to: Position) -> SnapshotCache? {
        guard from != to, position == from, let target = neighbour(forward: forward) else {
            return nil
        }
        return SnapshotCache(
            position: to, size: size, current: target,
            next: forward ? nil : current,
            previous: forward ? current : nil
        )
    }
}
