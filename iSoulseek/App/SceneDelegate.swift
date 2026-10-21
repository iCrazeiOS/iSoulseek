import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    private var root: RootViewController?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let root = RootViewController(client: .shared)
        self.root = root
        window.rootViewController = root
        self.window = window
        window.makeKeyAndVisible()

        // A launch straight from a Home Screen quick action is reported here rather than through
        // `windowScene(_:performActionFor:completionHandler:)`.
        if let shortcut = connectionOptions.shortcutItem,
           let tab = AppTab(shortcutType: shortcut.type) {
            root.openTab(tab)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard let tab = AppTab(shortcutType: shortcutItem.type) else {
            completionHandler(false)
            return
        }
        root?.openTab(tab)
        completionHandler(true)
    }
}
