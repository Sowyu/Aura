import XCTest

final class AuraUITestsLaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testReturningUserLaunch() {
        let app = XCUIApplication()
        // A returning user has completed setup. Keep all other production defaults.
        app.launchArguments = ["-browser.onboarding.completed", "YES"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.terminate()

        // Fresh processes with warm filesystem caches, not cold-boot measurements.
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.launch()
        }

        // Check a real keyboard action after launch, outside the launch metric.
        XCTAssertTrue(app.windows.firstMatch.exists)
        app.typeKey("t", modifierFlags: .command)
        let field = app.textFields["launcherField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        app.typeKey("a", modifierFlags: .command)
        field.typeText("launch check")
        XCTAssertEqual(field.value as? String, "launch check")
        app.terminate()
    }
}
