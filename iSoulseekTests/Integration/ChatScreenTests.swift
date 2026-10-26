import XCTest
@testable import iSoulseek

/// The chat screens and their tab, without driving the whole app.
final class ChatScreenTests: XCTestCase {

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

    func testChatRoomsScreenHasATable() {
        XCTAssertTrue(env.connectAndWaitForLogin())

        let controller = ChatRoomsViewController(client: env.client)
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()

        XCTAssertNotNil(firstView(of: UITableView.self, in: controller.view))
    }

    func testChatRoomScreenHasATableAndComposer() {
        XCTAssertTrue(env.connectAndWaitForLogin())

        let controller = ChatRoomViewController(room: "Music", client: env.client)
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()

        XCTAssertNotNil(firstView(of: UITableView.self, in: controller.view))
        XCTAssertNotNil(firstView(of: UITextField.self, in: controller.view))
        XCTAssertNotNil(firstView(of: UIButton.self, in: controller.view))
    }

    func testChatTabIsInTheTabBar() {
        XCTAssertTrue(env.connectAndWaitForLogin())

        let tabs = MainTabBarController(client: env.client)
        tabs.loadViewIfNeeded()

        XCTAssertEqual(tabs.viewControllers?.compactMap { $0.tabBarItem.title },
                       ["Search", "Transfers", "Chat", "Settings"])
    }

    private func firstView<T: UIView>(of type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(of: type, in: subview) { return match }
        }
        return nil
    }
}
