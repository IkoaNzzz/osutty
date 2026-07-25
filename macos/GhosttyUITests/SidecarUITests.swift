import AppKit
import XCTest

final class SidecarUITests: GhosttyCustomConfigCase {
    override static var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    @MainActor
    func testPanelsAndThemeCompatibility() async throws {
        try updateConfig(
            """
            title = SidecarUITests
            theme = light:3024 Day,dark:3024 Night
            window-theme = auto
            window-save-state = never
            """
        )
        XCUIDevice.shared.appearance = .light

        let app = try ghosttyApplication()
        app.launch()
        defer {
            app.terminate()
            XCUIDevice.shared.appearance = .unspecified
        }

        let titlebarToggle = app.buttons["sidecar-titlebar-toggle"].firstMatch
        XCTAssertTrue(titlebarToggle.waitForExistence(timeout: 5))
        titlebarToggle.click()
        let sidecar = app.descendants(matching: .any)["terminal-sidecar"].firstMatch
        XCTAssertTrue(sidecar.waitForExistence(timeout: 5))

        app.typeKey("s", modifierFlags: [.control, .command])
        XCTAssertTrue(sidecar.waitForNonExistence(timeout: 5))
        app.typeKey("s", modifierFlags: [.control, .command])
        XCTAssertTrue(sidecar.waitForExistence(timeout: 5))

        app.typeKey("p", modifierFlags: [.command, .shift])
        app.typeText("Close Sidecar")
        XCTAssertTrue(app.buttons["Close Sidecar"].firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.enter, modifierFlags: [])
        XCTAssertTrue(sidecar.waitForNonExistence(timeout: 5))

        app.typeKey("p", modifierFlags: [.command, .shift])
        app.typeText("Open Sidecar: Info")
        XCTAssertTrue(app.buttons["Open Sidecar: Info"].firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.enter, modifierFlags: [])
        XCTAssertTrue(sidecar.waitForExistence(timeout: 5))

        try await verifyPanel(
            in: app,
            "info",
            expectedElement: app.staticTexts["Working Directory"].firstMatch
        )
        try await verifyPanel(
            in: app,
            "outline",
            expectedElement: app.staticTexts["No Command Outline"].firstMatch
        )
        try await verifyPanel(
            in: app,
            "git",
            expectedElement: app.buttons["Commit"].firstMatch
        )
        try await verifyPanel(
            in: app,
            "files",
            expectedElement: app.textFields["Search files"].firstMatch
        )

        app.buttons["sidecar-tab-info"].firstMatch.click()
        try await Task.sleep(for: .milliseconds(300))

        let lightScreenshot = sidecar.screenshot()
        attach(lightScreenshot, name: "Sidecar - light 3024 Day")
        XCTAssertGreaterThan(
            try sampledLuminance(lightScreenshot.image),
            0.5,
            "The sidecar edge should follow the light terminal background."
        )

        XCUIDevice.shared.appearance = .dark
        try await Task.sleep(for: .seconds(1))

        let darkScreenshot = sidecar.screenshot()
        attach(darkScreenshot, name: "Sidecar - dark 3024 Night")
        XCTAssertLessThan(
            try sampledLuminance(darkScreenshot.image),
            0.5,
            "The sidecar edge should follow the dark terminal background."
        )

        app.terminate()
        try updateConfig(
            """
            title = SidecarUITests
            theme = 3024 Night
            window-theme = dark
            window-save-state = never
            background-opacity = 0.62
            background-blur = true
            """
        )

        let transparentApp = try ghosttyApplication()
        transparentApp.launchEnvironment["GHOSTTY_SIDECAR_VISIBLE"] = "1"
        transparentApp.launch()
        defer { transparentApp.terminate() }

        let transparentSidecar = transparentApp
            .descendants(matching: .any)["terminal-sidecar"]
            .firstMatch
        XCTAssertTrue(transparentSidecar.waitForExistence(timeout: 5))
        let transparentScreenshot = transparentSidecar.screenshot()
        attach(transparentScreenshot, name: "Sidecar - transparent background")
    }

    @MainActor
    private func verifyPanel(
        in app: XCUIApplication,
        _ panel: String,
        expectedElement: XCUIElement
    ) async throws {
        let button = app.buttons["sidecar-tab-\(panel)"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        button.click()
        XCTAssertTrue(expectedElement.waitForExistence(timeout: 5))
        try await Task.sleep(for: .milliseconds(100))
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func sampledLuminance(
        _ image: NSImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Double {
        guard let color = image.colorAt(x: 3, y: 10) else {
            throw XCTSkip("Unable to sample sidecar screenshot", file: file, line: line)
        }
        return color.luminance
    }
}
