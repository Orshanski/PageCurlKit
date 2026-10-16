import XCTest
@testable import PageCurlKit

final class ShaderUniformsLayoutTests: XCTestCase {

    func testSwiftFieldsMatchShaderStruct() throws {
        let source = pageCurlShaderSource
        let start = try XCTUnwrap(source.range(of: "struct CurlUniforms {"))
        let end = try XCTUnwrap(source.range(of: "};", range: start.upperBound..<source.endIndex))
        let shaderFields = source[start.upperBound..<end.lowerBound]
            .split(separator: "\n")
            .compactMap { line -> String? in
                let code = line.split(separator: "/").first ?? ""
                let words = code.split(whereSeparator: { $0 == " " || $0 == ";" })
                guard words.count == 2, words[0] == "float" else { return nil }
                return String(words[1])
            }
        let swiftFields = Mirror(reflecting: CurlUniforms()).children.compactMap(\.label)
        XCTAssertEqual(swiftFields, shaderFields)
    }

    func testLayoutIsTightFloats() {
        XCTAssertEqual(MemoryLayout<CurlUniforms>.size, 16 * MemoryLayout<Float>.size)
        XCTAssertEqual(MemoryLayout<CurlUniforms>.stride, MemoryLayout<CurlUniforms>.size)
    }
}
