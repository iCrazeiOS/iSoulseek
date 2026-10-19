import Combine
import UIKit

/// Sign-in form. Credentials are copied into the store, then the client connects.
final class LoginViewController: UIViewController {

    /// Layout metrics for the form. The column is as wide as the screen allows but never
    /// wider than `maxColumnWidth`, so the form reads the same on a phone and on an iPad.
    private enum Metrics {
        static let maxColumnWidth: CGFloat = 440
        static let horizontalInset: CGFloat = 24
        static let accessibilityHorizontalInset: CGFloat = 16
        static let verticalInset: CGFloat = 24
        static let spacing: CGFloat = 16
        static let accessibilitySpacing: CGFloat = 24
        static let statusSpacing: CGFloat = 8
        static let fieldMinHeight: CGFloat = 50
        static let buttonMinHeight: CGFloat = 48
        static let indicatorWidth: CGFloat = 20
    }

    private let client: SoulseekClient
    private var cancellables = Set<AnyCancellable>()

    private let scrollView = UIScrollView()
    private let container = UIView()
    private let contentStack = UIStackView()
    private let titleLabel = WrappingLabel()
    private let subtitleLabel = WrappingLabel()
    private let usernameField = InsetTextField()
    private let passwordField = InsetTextField()
    private let signInButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = WrappingLabel()
    private let statusRow = UIView()
    private let statusStack = UIStackView()
    private let footnoteLabel = WrappingLabel()

    /// Width of the form column. Kept as a constraint so the column follows the screen
    /// instead of being pinned to a fixed number of points.
    private var columnWidthConstraint: NSLayoutConstraint!
    private var columnAvailableConstraint: NSLayoutConstraint!

    /// Whether the status row is currently showing a failure.
    private var statusIsError = false

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
        applyMetrics()
        observeClient()

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        // The username is remembered for convenience; the password stays in the Keychain for
        // automatic sign-in and is not put into the form again.
        usernameField.text = client.store.username
        update(state: client.stateChanges.value)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory
                != traitCollection.preferredContentSizeCategory else { return }
        applyMetrics()
        updateTitleFont()
    }

    // MARK: Layout

    /// The title is a bold version of the large title font, kept in step with the
    /// user's text size.
    private func updateTitleFont() {
        let size = UIFont.preferredFont(forTextStyle: .largeTitle, compatibleWith: traitCollection).pointSize
        titleLabel.font = .systemFont(ofSize: size, weight: .bold)
    }

    private func buildLayout() {
        titleLabel.text = "iSoulseek"
        titleLabel.textAlignment = .center
        updateTitleFont()

        subtitleLabel.text = "Search, download, and share on Soulseek"
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center

        configure(usernameField, placeholder: "Username", contentType: .username, returnKey: .next)
        configure(passwordField, placeholder: "Password", contentType: .password, returnKey: .go)
        passwordField.isSecureTextEntry = true
        usernameField.clearButtonMode = .whileEditing
        usernameField.accessibilityIdentifier = "login.username"
        passwordField.accessibilityIdentifier = "login.password"
        signInButton.accessibilityIdentifier = "login.submit"
        usernameField.delegate = self
        passwordField.delegate = self

        var configuration = UIButton.Configuration.filled()
        configuration.title = "Sign in"
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { [weak self] incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .headline,
                                           compatibleWith: self?.traitCollection ?? UITraitCollection())
            return outgoing
        }
        signInButton.configuration = configuration
        signInButton.addTarget(self, action: #selector(signInTapped), for: .touchUpInside)

        spinner.hidesWhenStopped = true

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center

        footnoteLabel.text = "New usernames are created automatically\nPasswords cannot be reset"
        footnoteLabel.font = .preferredFont(forTextStyle: .footnote)
        footnoteLabel.adjustsFontForContentSizeCategory = true
        footnoteLabel.textColor = .tertiaryLabel
        footnoteLabel.textAlignment = .center

        // The spinner sits above the message and the message spans the whole form column.
        // A label that hugs its text sits exactly on the width where the text breaks, so a
        // short message can wrap; giving it the full column keeps it on one line and lets a
        // long one wrap across the column rather than being squeezed into a narrow block.
        statusStack.axis = .vertical
        statusStack.spacing = Metrics.statusSpacing
        statusStack.alignment = .center
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.addArrangedSubview(spinner)
        statusStack.addArrangedSubview(statusLabel)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusRow.addSubview(statusStack)
        statusRow.isHidden = true

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = Metrics.spacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        [titleLabel, subtitleLabel, usernameField, passwordField, signInButton, statusRow, footnoteLabel]
            .forEach { contentStack.addArrangedSubview($0) }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        // The scroll view already sits inside the safe area, so it must not add the
        // safe area insets a second time.
        scrollView.contentInsetAdjustmentBehavior = .never
        container.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        scrollView.addSubview(container)
        container.addSubview(contentStack)

        // The column fills the screen minus the insets, but stops at a comfortable
        // reading width on larger screens.
        columnWidthConstraint = contentStack.widthAnchor
            .constraint(equalTo: container.widthAnchor, constant: -2 * Metrics.horizontalInset)
        columnWidthConstraint.priority = .defaultHigh
        columnAvailableConstraint = contentStack.widthAnchor
            .constraint(lessThanOrEqualTo: container.widthAnchor, constant: -2 * Metrics.horizontalInset)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

            container.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            container.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            container.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),

            contentStack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            contentStack.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor,
                                              constant: Metrics.verticalInset),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor,
                                                 constant: -Metrics.verticalInset),
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.maxColumnWidth),
            columnWidthConstraint,
            columnAvailableConstraint,

            spinner.widthAnchor.constraint(equalToConstant: Metrics.indicatorWidth),
            statusLabel.widthAnchor.constraint(equalTo: statusRow.widthAnchor),
            statusStack.centerXAnchor.constraint(equalTo: statusRow.centerXAnchor),
            statusStack.topAnchor.constraint(equalTo: statusRow.topAnchor),
            statusStack.bottomAnchor.constraint(equalTo: statusRow.bottomAnchor),
            statusStack.leadingAnchor.constraint(greaterThanOrEqualTo: statusRow.leadingAnchor),
            statusStack.trailingAnchor.constraint(lessThanOrEqualTo: statusRow.trailingAnchor),
            usernameField.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.fieldMinHeight),
            passwordField.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.fieldMinHeight),
            signInButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.buttonMinHeight),
        ])
    }

    /// Applies the metrics that depend on the user's text size.
    private func applyMetrics() {
        let isAccessibility = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        contentStack.spacing = isAccessibility ? Metrics.accessibilitySpacing : Metrics.spacing

        let inset = isAccessibility ? Metrics.accessibilityHorizontalInset : Metrics.horizontalInset
        columnWidthConstraint.constant = -2 * inset
        columnAvailableConstraint.constant = -2 * inset
    }

    private func configure(_ field: InsetTextField, placeholder: String,
                           contentType: UITextContentType, returnKey: UIReturnKeyType) {
        field.placeholder = placeholder
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
            .sink { [weak self] message in self?.showMessage(message) }
            .store(in: &cancellables)
    }

    private func update(state: ConnectionState) {
        switch state {
        case .disconnected:
            setStatus(nil, isError: false)
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

    /// Shows `text` under the button. A `nil` text hides the row entirely.
    private func setStatus(_ text: String?, isError: Bool) {
        statusLabel.text = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabel
        statusRow.isHidden = text?.isEmpty ?? true
        statusIsError = isError
    }

    /// Shows a status message from the client, unless a failure is already being shown.
    private func showMessage(_ message: String) {
        guard !statusIsError else { return }
        setStatus(message, isError: false)
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

    func textFieldDidBeginEditing(_ textField: UITextField) {
        // The keyboard covers the lower half of the screen, so make sure the field
        // being edited stays visible.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let rect = textField.convert(textField.bounds, to: scrollView)
            scrollView.scrollRectToVisible(rect.insetBy(dx: 0, dy: -Metrics.verticalInset), animated: true)
        }
    }
}
