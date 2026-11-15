import XCTest

final class WorkspaceUITests: XCTestCase {
    @MainActor
    func testTabletLandscape() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.orcaslicer.ios")
        app.launchArguments = ["--test-view-metadata", "--test-document-import", "--test-native-picker"]
        app.launch()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 180), "System document picker must present")
        cancel.tap()
        let slice = app.buttons["slice-plate"]
        let imported = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            slice.exists && slice.isEnabled && slice.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [imported], timeout: 180), .completed,
                       "The native picker must finish import and dismiss before rotation")
        slice.tap()
        let export = app.buttons["Export G-code"]
        let preview = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningForeground && export.exists && export.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [preview], timeout: 180), .completed,
                       "The app must slice the imported model and present its processed preview")
        XCTAssertTrue(app.sliders["Upper preview layer"].exists)
        XCTAssertTrue(app.buttons["Prepare"].isHittable)
        XCTAssertTrue(app.buttons["Preview"].isHittable)
        XCTAssertTrue(app.buttons["Device"].isHittable)
        app.buttons["Preview controls"].tap()
        XCTAssertTrue(app.buttons["Hide preview controls"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Prepare"].isHittable, "Preview filters must not cover the main tabs")
        XCTAssertTrue(app.buttons["Device"].isHittable)
        app.buttons["Hide preview controls"].tap()
        let toolpaths = XCTAttachment(screenshot: app.screenshot())
        toolpaths.name = "toolpath-preview"
        toolpaths.lifetime = .keepAlways
        add(toolpaths)
        app.buttons["Prepare"].tap()
        app.buttons["model-library-shortcut"].tap()
        XCTAssertTrue(app.buttons["add-primitive"].waitForExistence(timeout: 10))
        app.buttons["add-primitive"].tap()
        XCTAssertTrue(slice.waitForExistence(timeout: 10))
        app.buttons["Objects and tools"].tap()
        XCTAssertTrue(app.buttons["mesh-tools"].waitForExistence(timeout: 10))
        app.buttons["mesh-tools"].tap()
        XCTAssertTrue(app.buttons["repair-mesh"].waitForExistence(timeout: 10))
        app.buttons["repair-mesh"].tap()
        let edited = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningForeground && slice.exists && slice.isEnabled && slice.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [edited], timeout: 180), .completed,
                       "Native mesh editing must finish and dismiss its inspector")
        XCUIDevice.shared.orientation = .landscapeRight
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningForeground && app.frame.width > app.frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 60), .completed)
        XCTAssertTrue(slice.isHittable, "Primary actions must remain reachable after rotation")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "tablet-landscape"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
