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
        try focusAndSearch("mp3")

        let result = app.cells["search.result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 90), "no search result arrived")

        app.tabBars.buttons["Transfers"].tap()
        XCTAssertTrue(app.navigationBars["Transfers"].waitForExistence(timeout: 10))

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    }

    /// Reproduces the reported symptom end to end: queue a download from search results, then
    /// check the Transfers screen shows it (Downloading) or completed it (Downloaded).
    func testQueuedDownloadShowsUpOnTheTransfersScreen() throws {
        let environment = ProcessInfo.processInfo.environment
        signInIfNeeded(username: environment["SOULSEEK_LIVE_USER"] ?? "",
                       password: environment["SOULSEEK_LIVE_PASS"] ?? "")

        let searchTab = app.tabBars.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 60), "never reached the main tabs")

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "no search field")
        searchField.tap()
        try focusAndSearch("flac")

        let result = app.cells["search.result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 90), "no search result arrived")

        result.tap()
        let downloadAction = app.sheets.buttons["Download"].firstMatch
        XCTAssertTrue(downloadAction.waitForExistence(timeout: 5), "no download action in the sheet")
        downloadAction.tap()

        let queuedToast = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Added' OR label CONTAINS 'downloading' OR label CONTAINS 'downloaded'")
        ).firstMatch
        XCTAssertTrue(queuedToast.waitForExistence(timeout: 15), "no queued toast after choosing Download")

        app.tabBars.buttons["Transfers"].tap()
        XCTAssertTrue(app.navigationBars["Transfers"].waitForExistence(timeout: 10))

        // Either a downloading row is on screen, or the transfer was over before we looked
        // (the tab title gains a count). Both mean the queue is no longer silently eaten.
        let counted = app.segmentedControls.buttons.matching(
            NSPredicate(format: "label MATCHES 'Downloading \\\\(\\\\d\\\\)' OR label MATCHES 'Downloaded \\\\(\\\\d\\\\)'")
        ).firstMatch
        let row = app.cells.firstMatch
        XCTAssertTrue(counted.waitForExistence(timeout: 30) || row.waitForExistence(timeout: 1),
                      "no visible transfer on the Transfers screen right after queueing")
    }

    /// Downloads a whole album from a browsed share and expects one honest summary toast.
    /// Guards the regression where the summary ran before the enqueues were counted and no
    /// toast appeared at all.
    func testAlbumDownloadShowsASummaryToast() throws {
        let environment = ProcessInfo.processInfo.environment
        signInIfNeeded(username: environment["SOULSEEK_LIVE_USER"] ?? "",
                       password: environment["SOULSEEK_LIVE_PASS"] ?? "")

        let searchTab = app.tabBars.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 60), "never reached the main tabs")

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "no search field")
        searchField.tap()
        try focusAndSearch("flac")

        let result = app.cells["search.result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 90), "no search result arrived")
        result.tap()

        let browseAction = app.sheets.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Browse'")
        ).firstMatch
        XCTAssertTrue(browseAction.waitForExistence(timeout: 5), "no browse action in the sheet")
        browseAction.tap()

        // The first folder header with files offers its own Download button.
        let headerDownload = app.buttons.matching(
            NSPredicate(format: "label == 'Download' AND isEnabled == true")
        ).firstMatch
        XCTAssertTrue(headerDownload.waitForExistence(timeout: 90),
                      "the browsed share never showed a downloadable folder")

        headerDownload.tap()
        let toast = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Queued' OR label CONTAINS 'already' OR label CONTAINS 'could not be added'")
        ).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 15), "no summary toast appeared for the album download")
    }


    /// Types `query` into the search field and submits it, retrying the tap when the first focus
    /// misses. The search key is tapped explicitly; the trailing newline of `typeText` does not
    /// reliably trigger the return key on `UISearchBar`.
    private func focusAndSearch(_ query: String) throws {
        let searchField = app.searchFields.firstMatch
        for _ in 0..<2 {
            searchField.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 3) { break }
        }
        searchField.typeText(query)
        let searchKey = app.keyboards.buttons.matching(
            NSPredicate(format: "label ==[c] 'search' OR label ==[c] 'return' OR label ==[c] 'go'")
        ).firstMatch
        if searchKey.waitForExistence(timeout: 2) {
            searchKey.tap()
        } else {
            searchField.typeText("\n")
        }
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
