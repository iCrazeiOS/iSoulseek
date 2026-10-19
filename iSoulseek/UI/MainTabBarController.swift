import UIKit

/// Top-level container once the user is signed in.
final class MainTabBarController: UITabBarController {

    private let client: SoulseekClient

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
        let downloads = DownloadsViewController(client: client)
        let settings = SettingsViewController(client: client)

        viewControllers = [
            wrap(search, title: "Search", symbol: "magnifyingglass"),
            wrap(downloads, title: "Downloads", symbol: "arrow.down.circle"),
            wrap(settings, title: "Settings", symbol: "gearshape"),
        ]
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
