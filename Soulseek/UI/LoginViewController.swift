import Combine
import UIKit

/// Sign-in form. Credentials are copied into the store, then the client connects.
final class LoginViewController: UIViewController {

    private let client: SoulseekClient
    private var cancellables = Set<AnyCancellable>()

    private let scrollView = UIScrollView()
    private let container = UIView()
    private let contentStack = UIStackView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let usernameField = UITextField()
    private let passwordField = UITextField()
    private let signInButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private let footnoteLabel = UILabel()

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
        buildLayout()
        observeClient()

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        usernameField.text = client.store.username
        passwordField.text = client.store.password
        update(state: client.stateChanges.value)
    }

    // MARK: Layout

    private func buildLayout() {
        titleLabel.text = "Soulseek"
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center

        subtitleLabel.text = "Search, browse and download from the Soulseek network."
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        configure(usernameField, placeholder: "Username", contentType: .username, returnKey: .next)
        configure(passwordField, placeholder: "Password", contentType: .password, returnKey: .go)
        passwordField.isSecureTextEntry = true
        usernameField.delegate = self
        passwordField.delegate = self

        var configuration = UIButton.Configuration.filled()
        configuration.title = "Sign in"
        configuration.cornerStyle = .medium
        signInButton.configuration = configuration
        signInButton.addTarget(self, action: #selector(signInTapped), for: .touchUpInside)

        spinner.hidesWhenStopped = true

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center

        footnoteLabel.text = "A new username is registered automatically the first time you sign in. "
            + "There is no password reset, so choose a password you will remember."
        footnoteLabel.font = .preferredFont(forTextStyle: .footnote)
        footnoteLabel.adjustsFontForContentSizeCategory = true
        footnoteLabel.textColor = .tertiaryLabel
        footnoteLabel.numberOfLines = 0
        footnoteLabel.textAlignment = .center

        let statusRow = UIStackView(arrangedSubviews: [spinner, statusLabel])
        statusRow.axis = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .center

        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.alignment = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        [titleLabel, subtitleLabel, usernameField, passwordField, signInButton, statusRow, footnoteLabel]
            .forEach { contentStack.addArrangedSubview($0) }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        container.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        scrollView.addSubview(container)
        container.addSubview(contentStack)

        let width = contentStack.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -48)
        width.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

            container.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            container.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            container.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),

            contentStack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            contentStack.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -24),
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            width,

            usernameField.heightAnchor.constraint(equalToConstant: 44),
            passwordField.heightAnchor.constraint(equalToConstant: 44),
            signInButton.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    private func configure(_ field: UITextField, placeholder: String,
                           contentType: UITextContentType, returnKey: UIReturnKeyType) {
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.textContentType = contentType
        field.returnKeyType = returnKey
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
    }

    // MARK: Client

    private func observeClient() {
        client.stateChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.update(state: state) }
            .store(in: &cancellables)

        client.messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in self?.setStatus(message, isError: false) }
            .store(in: &cancellables)
    }

    private func update(state: ConnectionState) {
        switch state {
        case .disconnected:
            setStatus("Not connected", isError: false)
            setBusy(false)
        case .connecting, .connectingToServer:
            setStatus(state.description, isError: false)
            setBusy(true)
        case .loggedIn:
            setStatus(state.description, isError: false)
            setBusy(true)
        case .failed(let reason):
            setStatus(reason, isError: true)
            setBusy(false)
        }
    }

    private func setBusy(_ busy: Bool) {
        if busy {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        signInButton.isEnabled = !busy
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusLabel.text = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabel
    }

    // MARK: Actions

    @objc private func signInTapped() {
        view.endEditing(true)
        let username = (usernameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            setStatus("Enter your Soulseek username", isError: true)
            return
        }
        guard let password = passwordField.text, !password.isEmpty else {
            setStatus("Enter your Soulseek password", isError: true)
            return
        }
        client.store.username = username
        client.store.password = password
        client.connect()
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }
}

// MARK: - UITextFieldDelegate

extension LoginViewController: UITextFieldDelegate {

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === usernameField {
            passwordField.becomeFirstResponder()
        } else {
            signInTapped()
        }
        return true
    }
}
