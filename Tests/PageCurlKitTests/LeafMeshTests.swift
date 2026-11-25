import XCTest
@testable import PageCurlKit

final class LeafMeshTests: XCTestCase {

    /// Columns between the vertices of the top row, the one at sheet y = 0.
    private func columns(_ mesh: LeafMeshGeometry) -> Int {
        stride(from: 1, to: mesh.vertices.count, by: 4).filter { mesh.vertices[$0] == 0 }.count - 1
    }

    func testGridAboutEveryTwoPoints() {
        let mesh = LeafMeshGeometry(width: 1000, height: 600, step: LeafMeshGeometry.leafStep)
        XCTAssertEqual(columns(mesh), 500)
        XCTAssertEqual(mesh.indices.count / (columns(mesh) * 6), 300, "Rows about every two points")
        XCTAssertEqual(columns(LeafMeshGeometry(width: 2, height: 600, step: LeafMeshGeometry.leafStep)), 2, "At least two columns")
    }

    func testCountsAndIndicesInRange() {
        let mesh = LeafMeshGeometry(width: 400, height: 600, step: LeafMeshGeometry.leafStep)
        let rows = mesh.indices.count / (columns(mesh) * 6)
        let vertexCount = (columns(mesh) + 1) * (rows + 1)
        XCTAssertEqual(mesh.vertices.count, vertexCount * 4)
        XCTAssertTrue(mesh.indices.allSatisfy { Int($0) < vertexCount })
    }

    func testCoversTheSheetAndTheSnapshot() {
        let mesh = LeafMeshGeometry(width: 400, height: 600, step: LeafMeshGeometry.leafStep)
        let last = mesh.vertices.count - 4
        XCTAssertEqual(Array(mesh.vertices[0..<4]), [0, 0, 0, 0])
        XCTAssertEqual(Array(mesh.vertices[last...]), [400, 600, 1, 1])
    }

    func testTrianglesWindCounterClockwiseOnScreen() {
        // The shader puts sheet y downward on screen; the scene of an unmirrored curl expects the
        // front of the leaf to be wound counter-clockwise.
        XCTAssertTrue(CurlScene(isSpread: false, forward: true).frontFacesCounterClockwise)
        let mesh = LeafMeshGeometry(width: 40, height: 60, step: LeafMeshGeometry.leafStep)
        func point(_ index: UInt32) -> (x: Float, y: Float) {
            let i = Int(index) * 4
            return (mesh.vertices[i], -mesh.vertices[i + 1])
        }
        for triangle in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = point(mesh.indices[triangle])
            let b = point(mesh.indices[triangle + 1])
            let c = point(mesh.indices[triangle + 2])
            let area = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
            XCTAssertGreaterThan(area, 0, "Triangle \(triangle / 3) is wound clockwise")
        }
    }
}
