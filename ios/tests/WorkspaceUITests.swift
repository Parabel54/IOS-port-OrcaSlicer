import XCTest

final class WorkspaceUITests: XCTestCase {
    @MainActor
    private func openSlicedPreview(_ app: XCUIApplication) {
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
    }

    @MainActor
    func testPreviewNavigation() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.orcaslicer.ios")
        app.launchArguments = ["--test-document-import", "--test-native-picker", "--test-preview-memory-warning"]
        app.launch()
        openSlicedPreview(app)
        XCTAssertFalse(app.staticTexts["Slice the plate to preview toolpaths"].exists, "Memory pressure must retain the successful slice")
        XCTAssertTrue(app.buttons["camera-home"].isHittable)
        XCTAssertTrue(app.otherElements["Navigation cube"].exists)
        app.buttons["camera-home"].tap()
        app.buttons["Preview controls"].tap()
        XCTAssertTrue(app.buttons["Hide preview controls"].waitForExistence(timeout: 10))
        let information = app.buttons["Model and slice information"]
        XCTAssertTrue(information.isHittable)
        XCTAssertFalse(information.frame.intersects(app.otherElements["Navigation cube"].frame),
                       "The information action must not cover the navigation cube")
        for title in ["Prepare", "Preview", "Device"] {
            XCTAssertTrue(app.buttons[title].isHittable, "Main tabs must remain visible above Preview controls")
        }
        let files = app.buttons["File and project actions"]
        XCTAssertTrue(files.isHittable, "Preview controls must leave the Files action reachable")
        XCTAssertTrue(app.buttons["Export G-code"].isHittable, "Preview controls must leave Export reachable")
        files.tap()
        XCTAssertTrue(app.buttons["Open model…"].waitForExistence(timeout: 10))
        app.buttons["Open model…"].tap()
        openSlicedPreview(app)
        app.buttons["Preview controls"].tap()
        XCTAssertTrue(app.buttons["Hide preview controls"].waitForExistence(timeout: 10))
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.progressIndicators["preview-building"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 60), .completed)
        app.buttons["Hide preview controls"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "preview-navigation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Device"].tap()
        XCTAssertTrue(app.buttons["Prepare"].isHittable)
        app.buttons["Prepare"].tap()
        XCTAssertTrue(app.buttons["slice-plate"].isHittable)
        XCTAssertTrue(app.buttons["camera-home"].isHittable, "Home must remain visible in Prepare without scrolling tools")
        app.buttons["camera-home"].tap()
        app.buttons["Preview"].tap()
        XCTAssertTrue(app.sliders["Upper preview layer"].exists)
    }

    @MainActor
    func testGCodePreview() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.orcaslicer.ios")
        app.launchArguments = ["--test-document-import", "--test-gcode-import"]
        app.launch()
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningForeground && app.buttons["Export G-code"].isHittable &&
                app.sliders["Upper preview layer"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 180), .completed,
                       "Opening G-code must produce a preview without loading or slicing a model")
        app.buttons["Preview controls"].tap()
        XCTAssertTrue(app.buttons["Hide preview controls"].waitForExistence(timeout: 10))
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningForeground && !app.progressIndicators["preview-building"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 60), .completed)
        app.buttons["Hide preview controls"].tap()
        XCTAssertTrue(app.buttons["Device"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "standalone-gcode-preview"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Prepare"].tap()
        XCTAssertFalse(app.buttons["slice-plate"].isEnabled, "The viewed G-code must not become an editable mesh")
    }

    @MainActor
    func testTabletLandscape() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.orcaslicer.ios")
        app.launchArguments = ["--test-view-metadata", "--test-document-import", "--test-native-picker"]
        app.launch()
        openSlicedPreview(app)
        let slice = app.buttons["slice-plate"]
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
