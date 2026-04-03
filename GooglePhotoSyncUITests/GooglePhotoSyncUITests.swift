import XCTest

final class GooglePhotoSyncUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunchesAndShowsDashboard() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_DISABLE_BOOTSTRAP"] = "1"
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.navigationBars["Google Photo Sync"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Google sign-in missing"].exists)
        XCTAssertFalse(app.buttons["Install Latest Build"].exists)
    }
}
