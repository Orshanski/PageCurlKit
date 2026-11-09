/// One of the two snapshots of a turn.
enum CurlSnapshot: Equatable {
    /// What is on screen before the turn.
    case current
    /// What is on screen after it.
    case target
}

/// A screen area covered by a background snapshot.
enum BackgroundQuad: CaseIterable {
    case left
    case right
    case full

    /// Two triangles in NDC as (x, y, u, v); v=0 is the top of the snapshot.
    var vertices: [Float] {
        let (x0, x1, u0, u1): (Float, Float, Float, Float)
        switch self {
        case .left: (x0, x1, u0, u1) = (-1, 0, 0, 0.5)
        case .right: (x0, x1, u0, u1) = (0, 1, 0.5, 1)
        case .full: (x0, x1, u0, u1) = (-1, 1, 0, 1)
        }
        return [
            x0, -1, u0, 1, x0, 1, u0, 0, x1, -1, u1, 1,
            x1, -1, u1, 1, x0, 1, u0, 0, x1, 1, u1, 0,
        ]
    }
}

/// What the curl view draws for one turn: which snapshot lies where, which one is the leaf, and
/// how time runs. The view only binds textures by this plan.
struct CurlScene: Equatable {
    struct Background: Equatable {
        let quad: BackgroundQuad
        let snapshot: CurlSnapshot
    }

    let backgrounds: [Background]
    /// The snapshot on the front of the leaf.
    let leafFace: CurlSnapshot
    /// The snapshot the shader samples for the back of the leaf.
    let leafBack: CurlSnapshot
    /// Single page backward plays the forward trajectory with time reversed.
    let reversesTime: Bool
    /// The leaf mesh is wound counter-clockwise; a mirrored curl flips it.
    let frontFacesCounterClockwise: Bool

    init(isSpread: Bool, forward: Bool) {
        if isSpread {
            // The half that stays comes from the current snapshot, the half being revealed from
            // the target.
            backgrounds = forward
                ? [Background(quad: .left, snapshot: .current), Background(quad: .right, snapshot: .target)]
                : [Background(quad: .left, snapshot: .target), Background(quad: .right, snapshot: .current)]
            leafFace = .current
        } else {
            // Going forward the target lies underneath; going backward the target curls back in
            // over the current page.
            backgrounds = [Background(quad: .full, snapshot: forward ? .target : .current)]
            leafFace = forward ? .current : .target
        }
        leafBack = .target
        reversesTime = !isSpread && !forward
        frontFacesCounterClockwise = CurlTrajectory.direction(isSpread: isSpread, forward: forward) > 0
    }

    func trajectoryProgress(_ progress: Float) -> Float {
        reversesTime ? 1 - progress : progress
    }
}

/// The flat leaf as a grid in sheet points, wound counter-clockwise on screen.
struct LeafMeshGeometry {
    static let rows = 24

    let columns: Int
    /// Four floats per vertex: x, y in sheet points and u, v in the snapshot.
    let vertices: [Float]
    let indices: [UInt32]

    /// About 5 pt between columns, across the fold where the sheet bends; rows can be coarse.
    init(width: Float, height: Float) {
        let columns = max(2, Int(width / 5))
        let rows = Self.rows
        var vertices: [Float] = []
        vertices.reserveCapacity((columns + 1) * (rows + 1) * 4)
        for row in 0...rows {
            let v = Float(row) / Float(rows)
            for column in 0...columns {
                let u = Float(column) / Float(columns)
                vertices.append(contentsOf: [u * width, v * height, u, v])
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(columns * rows * 6)
        let stride = UInt32(columns + 1)
        for row in 0..<UInt32(rows) {
            for column in 0..<UInt32(columns) {
                let a = row * stride + column
                let b = a + 1
                let c = a + stride
                let d = c + 1
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        self.columns = columns
        self.vertices = vertices
        self.indices = indices
    }
}
