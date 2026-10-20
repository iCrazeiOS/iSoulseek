import XCTest
@testable import iSoulseek

/// Behaviour of the Search screen itself, driven through its search bar.
final class SearchScreenTests: XCTestCase {

    private var env: TestEnvironment!

    override func setUpWithError() throws {
        try super.setUpWithError()
        env = TestEnvironment()
    }

    override func tearDownWithError() throws {
        env?.tearDown()
        env = nil
        try super.tearDownWithError()
    }

    /// The search bar's cancel button (shown as an X on iOS 26) empties the field and returns the
    /// screen to its starting state instead of leaving the old results behind.
    func testCancelButtonClearsTheQueryAndTheResults() {
        env.peer.searchFiles = [
            ShareFile(name: "Music\\song.mp3", size: 10, fileExtension: "mp3")
        ]
        XCTAssertTrue(env.connectAndWaitForLogin())

        let controller = SearchViewController(client: env.client)
        controller.loadViewIfNeeded()

        guard let searchBar = firstView(of: UISearchBar.self, in: controller.view),
              let tableView = firstView(of: UITableView.self, in: controller.view) else {
            return XCTFail("the search screen has no search bar or table")
        }
        XCTAssertNotNil(label(withText: "Find music", in: controller.view))

        searchBar.text = "song"
        controller.searchBarSearchButtonClicked(searchBar)
        assertEventually("the search never displayed a result", timeout: 5) {
            tableView.numberOfSections > 0
        }

        controller.searchBarCancelButtonClicked(searchBar)

        XCTAssertEqual(searchBar.text, "", "the query was left in the field")
        XCTAssertEqual(tableView.numberOfSections, 0, "results stayed on screen after cancelling")
        assertEventually("the starting message did not come back", timeout: 2) {
            label(withText: "Find music", in: controller.view) != nil
        }
    }

    private func firstView<T: UIView>(of type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(of: type, in: subview) { return match }
        }
        return nil
    }

    private func label(withText text: String, in view: UIView) -> UILabel? {
        if let label = view as? UILabel, label.text == text { return label }
        for subview in view.subviews {
            if let match = label(withText: text, in: subview) { return match }
        }
        return nil
    }
}
