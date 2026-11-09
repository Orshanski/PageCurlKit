import XCTest
import UIKit
@testable import PageCurlKit

/// The controller keeps one curl view and tells it exactly which turn to play.
@MainActor
final class ControllerViewTests: ControllerTestCase {

    func testOneViewForAllTurns() async {
        controller.warmUp()
        await completeBeautifulTurn()
        time += 10
        await completeBeautifulTurn()
        XCTAssertEqual(factory.makeCalls, 1, "The view is made once and reused")
    }

    func testBackgroundReleasesTextures() async {
        controller.warmUp()
        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        XCTAssertEqual(overlay.textureReleases, 1, "Going to the background frees the textures")
    }

    func testRequestDescribesTheTurn() async {
        host.paperColor = .black
        container.backgroundColor = .white
        await completeBeautifulTurn(forward: true, isSpread: false)
        time += 10
        await completeBeautifulTurn(forward: false, isSpread: true)

        let single = overlay.requests[0]
        XCTAssertEqual(single.paperColor, .black, "Paper comes from the host, not the container")
        XCTAssertTrue(single.forward)
        XCTAssertFalse(single.isSpread)
        XCTAssertEqual(single.sizePoints, containerSize)

        let spread = overlay.requests[1]
        XCTAssertFalse(spread.forward)
        XCTAssertTrue(spread.isSpread)
        XCTAssertEqual(spread.sizePoints, containerSize)
    }
}
