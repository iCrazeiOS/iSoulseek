import Combine
import UIKit

/// Hosts the login screen until the client is signed in, then the main tab bar.
final class RootViewController: UIViewController {

    private let client: SoulseekClient
    private var cancellables = Set<AnyCancellable>()

    private var current: UIViewController?
    private var loginViewController: LoginViewController?
    private var mainViewController: MainTabBarController?

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
        view.backgroundColor = .systemBackground
        client.stateChanges
            .sink { [weak self] state in self?.present(state) }
            .store(in: &cancellables)
    }

    private func present(_ state: ConnectionState) {
        if state.isLoggedIn {
            guard !(current is MainTabBarController) else { return }
            let main = mainViewController ?? MainTabBarController(client: client)
            mainViewController = main
            // Every sign-in starts on Search, even when the tab bar was kept from an earlier session.
            main.resetToSearch()
            swap(to: main)
        } else {
            guard !(current is LoginViewController) else { return }
            let login = loginViewController ?? LoginViewController(client: client)
            loginViewController = login
            swap(to: login)
        }
    }

    private func swap(to next: UIViewController) {
        guard current !== next else { return }

        next.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(next)
        next.view.alpha = 0
        view.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.topAnchor.constraint(equalTo: view.topAnchor),
            next.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            next.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        next.didMove(toParent: self)

        let previous = current
        current = next
        UIView.animate(withDuration: previous == nil ? 0 : 0.25) {
            next.view.alpha = 1
            previous?.view.alpha = 0
        } completion: { _ in
            guard let previous else { return }
            previous.willMove(toParent: nil)
            previous.view.removeFromSuperview()
            previous.removeFromParent()
        }
    }
}
