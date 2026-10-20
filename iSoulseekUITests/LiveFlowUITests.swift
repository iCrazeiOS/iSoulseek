import XCTest

/// Drives the real app against the real network. Skipped unless `SOULSEEK_LIVE=1` and credentials
/// are supplied, so a normal test run never touches the internet.
final class LiveFlowUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()

        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["SOULSEEK_LIVE"] == "1",
                          "Set SOULSEEK_LIVE=1 to run the UI flow")
        try XCTSkipIf(environment["SOULSEEK_LIVE_USER"]?.isEmpty ?? true
                        || environment["SOULSEEK_LIVE_PASS"]?.isEmpty ?? true,
                      "SOULSEEK_LIVE_USER and SOULSEEK_LIVE_PASS must both be set")

        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testLoginSearchAndTabs() throws {
        let environment = ProcessInfo.processInfo.environment
        signInIfNeeded(username: environment["SOULSEEK_LIVE_USER"] ?? "",
                       password: environment["SOULSEEK_LIVE_PASS"] ?? "")

        let searchTab = app.tabBars.buttons["Search"]
        if !searchTab.waitForExistence(timeout: 60) {
            XCTFail("never reached the main tabs. Screen:\n\(app.debugDescription)")
            return
        }

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "no search field")
        searchField.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) {
            searchField.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "search field never focused")
        searchField.typeText("mp3\n")

        let result = app.cells["search.result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 90), "no search result arrived")

        app.tabBars.buttons["Transfers"].tap()
        XCTAssertTrue(app.navigationBars["Transfers"].waitForExistence(timeout: 10))

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    }

    private func signInIfNeeded(username: String, password: String) {
        let usernameField = app.textFields["login.username"]
        // Stored credentials sign in automatically, so the form may never appear. If it does,
        // fill it in; otherwise the caller waits for the tabs while the session connects.
        guard usernameField.waitForExistence(timeout: 5) else { return }

        clear(usernameField)
        usernameField.tap()
        usernameField.typeText(username)

        let passwordField = app.secureTextFields["login.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5), "no password field")
        clear(passwordField)
        passwordField.tap()
        passwordField.typeText(password)

        // The software keyboard's window swallows taps aimed at the button, so dismiss it first.
        app.staticTexts["iSoulseek"].firstMatch.tap()
        app.buttons["login.submit"].tap()
    }

    /// The login screen remembers the last username, so fields must be emptied before typing.
    private func clear(_ field: XCUIElement) {
        field.tap()
        guard let value = field.value as? String, !value.isEmpty,
              value != field.placeholderValue else { return }
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
    }
}
