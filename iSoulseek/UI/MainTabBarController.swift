import UIKit

/// Top-level container once the user is signed in.
final class MainTabBarController: UITabBarController {

    private static let searchIndex = 0
    private static let transfersIndex = 1

    private let client: SoulseekClient
    private var transfers: TransfersViewController?

    init(client: SoulseekClient) {
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Without this the bar turns transparent when a tab's table view reaches its bottom.
        tabBar.scrollEdgeAppearance = tabBar.standardAppearance

        let search = SearchViewController(client: client)
        let transfers = TransfersViewController(client: client)
        self.transfers = transfers
        let settings = SettingsViewController(client: client)

        viewControllers = [
            wrap(search, title: "Search", symbol: "magnifyingglass"),
            wrap(transfers, title: "Transfers", symbol: "arrow.up.arrow.down"),
            wrap(settings, title: "Settings", symbol: "gearshape"),
        ]

        open(client.store.startupTab)
    }

    /// Shows `tab`, choosing the Downloaded segment for `.downloads` so the quick action lands on
    /// actual files rather than whichever segment was last open.
    func open(_ tab: AppTab) {
        switch tab {
        case .search:
            selectedIndex = Self.searchIndex
        case .downloads:
            selectedIndex = Self.transfersIndex
            transfers?.showTab(.downloaded)
        }
    }

    private func wrap(_ viewController: UIViewController, title: String, symbol: String) -> UINavigationController {
        viewController.tabBarItem = UITabBarItem(title: title,
                                                 image: UIImage(systemName: symbol),
                                                 selectedImage: nil)
        let navigation = UINavigationController(rootViewController: viewController)
        navigation.navigationBar.prefersLargeTitles = true
        return navigation
    }
}
