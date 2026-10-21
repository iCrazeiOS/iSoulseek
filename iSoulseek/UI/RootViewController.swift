import Combine
import UIKit

/// Hosts the launch/connecting screen, the login form, and the main tab bar.
///
/// A stored password is a session: when one exists the app connects immediately and keeps
/// reconnecting instead of falling back to the login form. The login form only appears when
/// there is no saved session or the server rejects the credentials.
final class RootViewController: UIViewController {

    private let client: SoulseekClient
    private var cancellables = Set<AnyCancellable>()

    private var current: UIViewController?
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0

    /// A Home Screen quick action's destination, held until the tab bar is on screen. The user may
    /// still have to sign in first, so the request outlives the login screen.
    private var pendingTab: AppTab?

    init(client: SoulseekClient) {
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // The client publishes on the main queue and replays its current value, so this also
        // chooses the first screen synchronously.
        client.stateChanges
            .sink { [weak self] state in self?.present(state) }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationWillEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification,
                                               object: nil)
    }

    private func present(_ state: ConnectionState) {
        switch state {
        case .loggedIn:
            cancelReconnect()
            showMain()

        case .failed:
            // The server rejected the saved credentials (or they are locally invalid), so this
            // is the one case that should return the user to the login form.
            cancelReconnect()
            showLogin()

        case .disconnected:
            guard client.store.isConfigured else {
                cancelReconnect()
                showLogin()
                return
            }
            // A drop after signing in keeps the tabs on screen; only launch and reconnect
            // attempts show the connecting screen.
            if !(current is MainTabBarController) {
                showConnecting(state: state)
            }
            scheduleReconnect()

        case .connecting, .connectingToServer:
            // A manual sign-in keeps the login form (with its own spinner) on screen.
            if current is LoginViewController || current is MainTabBarController { return }
            showConnecting(state: state)
        }
    }

    // MARK: Reconnecting

    /// Retries the stored session, backing off so an unavailable server is not hammered. The
    /// first attempt is immediate, then 1, 2, 4… seconds up to 30.
    private func scheduleReconnect() {
        guard client.store.isConfigured, reconnectWorkItem == nil else { return }

        let delay: TimeInterval = reconnectAttempt == 0
            ? 0
            : min(pow(2, Double(reconnectAttempt - 1)), 30)
        reconnectAttempt += 1

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            guard self.client.store.isConfigured,
                  case .disconnected = self.client.stateChanges.value else { return }
            self.client.connect()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempt = 0
    }

    @objc private func applicationWillEnterForeground() {
        guard client.store.isConfigured,
              case .disconnected = client.stateChanges.value else { return }
        cancelReconnect()
        scheduleReconnect()
    }

    // MARK: Quick actions

    /// Opens `tab` now, or as soon as the tab bar can be shown.
    func openTab(_ tab: AppTab) {
        pendingTab = tab
        guard let tabs = current as? MainTabBarController else { return }
        showPendingTab(in: tabs)
    }

    private func showPendingTab(in tabs: MainTabBarController) {
        guard let tab = pendingTab else { return }
        pendingTab = nil
        tabs.open(tab)
    }

    // MARK: Screens

    private func showMain() {
        if let tabs = current as? MainTabBarController {
            showPendingTab(in: tabs)
            return
        }
        let tabs = MainTabBarController(client: client)
        swap(to: tabs)
        showPendingTab(in: tabs)
    }

    private func showLogin() {
        guard !(current is LoginViewController) else { return }
        swap(to: LoginViewController(client: client))
    }

    private func showConnecting(state: ConnectionState) {
        if let connecting = current as? ConnectingViewController {
            connecting.update(state: state)
            return
        }
        let connecting = ConnectingViewController()
        connecting.onSignIn = { [weak self] in self?.signInInstead() }
        swap(to: connecting)
        connecting.update(state: state)
    }

    /// Leaves the automatic session attempt and lets the user enter different credentials.
    /// `signOut()` emits `.disconnected`, which brings up the login form.
    private func signInInstead() {
        cancelReconnect()
        client.signOut()
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

// MARK: - ConnectingViewController

/// Shown while a saved session connects or reconnects. Keeping this separate from the login
/// form means a slow or unavailable network never looks like a credentials problem.
private final class ConnectingViewController: UIViewController {

    var onSignIn: (() -> Void)?

    private let messageView = MessageView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        messageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageView)

        NSLayoutConstraint.activate([
            messageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            messageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            messageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            messageView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    func update(state: ConnectionState) {
        let title: String
        switch state {
        case .connectingToServer:
            title = "Signing in…"
        default:
            title = "Connecting…"
        }
        messageView.configure(title: title,
                              message: "Connecting to the Soulseek network.",
                              loading: true,
                              actionTitle: "Sign in with a different account",
                              onAction: { [weak self] in self?.onSignIn?() })
    }
}
