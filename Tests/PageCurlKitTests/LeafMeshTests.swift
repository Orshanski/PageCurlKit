import XCTest
@testable import PageCurlKit

final class LeafMeshTests: XCTestCase {

    func testColumnsAboutEveryFivePoints() {
        XCTAssertEqual(LeafMeshGeometry(width: 1000, height: 600).columns, 200)
        XCTAssertEqual(LeafMeshGeometry(width: 4, height: 600).columns, 2, "At least two columns")
    }

    func testCountsAndIndicesInRange() {
        let mesh = LeafMeshGeometry(width: 400, height: 600)
        let rows = LeafMeshGeometry.rows
        let vertexCount = (mesh.columns + 1) * (rows + 1)
        XCTAssertEqual(mesh.vertices.count, vertexCount * 4)
        XCTAssertEqual(mesh.indices.count, mesh.columns * rows * 6)
        XCTAssertTrue(mesh.indices.allSatisfy { Int($0) < vertexCount })
    }

    func testCoversTheSheetAndTheSnapshot() {
        let mesh = LeafMeshGeometry(width: 400, height: 600)
        let last = mesh.vertices.count - 4
        XCTAssertEqual(Array(mesh.vertices[0..<4]), [0, 0, 0, 0])
        XCTAssertEqual(Array(mesh.vertices[last...]), [400, 600, 1, 1])
    }

    func testTrianglesWindCounterClockwiseOnScreen() {
        // The shader puts sheet y downward on screen; the scene of an unmirrored curl expects the
        // front of the leaf to be wound counter-clockwise.
        XCTAssertTrue(CurlScene(isSpread: false, forward: true).frontFacesCounterClockwise)
        let mesh = LeafMeshGeometry(width: 40, height: 60)
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
