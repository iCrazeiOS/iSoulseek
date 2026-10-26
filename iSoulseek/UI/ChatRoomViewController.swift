import Combine
import UIKit

/// A single joined room: transcript, user list and composer.
final class ChatRoomViewController: UIViewController {

    private let room: String
    private let client: SoulseekClient
    private var cancellables = Set<AnyCancellable>()

    private var messages: [ChatMessage] = []
    private var users: [ChatRoomUser] = []
    private var hasJoined = false
    /// Set when this screen is being popped, so the leave we requested is not mistaken for a kick.
    private var isLeaving = false

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let messageView = MessageView()
    private let composer = UIView()
    private let textField = InsetTextField()
    private let sendButton = UIButton(type: .system)

    private lazy var usersItem = UIBarButtonItem(title: "Users",
                                                 style: .plain,
                                                 target: self,
                                                 action: #selector(showUsers))

    init(room: String, client: SoulseekClient) {
        self.room = room
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = room
        view.backgroundColor = .systemBackground

        configureTable()
        configureComposer()
        configureLayout()
        configureNavigation()
        observeClient()
        updateUsersItem()
        showJoining()

        // Joining here rather than from the room list means the room screen is already listening
        // when the server replies with its user list.
        client.joinRoom(room)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Switching tabs keeps the room joined; popping the screen leaves it. Using
        // `viewDidDisappear` avoids leaving the room when an interactive back swipe is cancelled.
        if isMovingFromParent {
            isLeaving = true
            client.leaveRoom(room)
        }
    }

    // MARK: Setup

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .interactive
        tableView.register(ChatMessageCell.self, forCellReuseIdentifier: ChatMessageCell.reuseIdentifier)
    }

    private func configureComposer() {
        composer.backgroundColor = .systemBackground
        composer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composer)

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        composer.addSubview(separator)

        textField.placeholder = "Message \(room)"
        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.returnKeyType = .send
        textField.enablesReturnKeyAutomatically = true
        textField.delegate = self
        textField.translatesAutoresizingMaskIntoConstraints = false

        sendButton.setImage(UIImage(systemName: "arrow.up.circle.fill"), for: .normal)
        sendButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold),
            forImageIn: .normal)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.accessibilityLabel = "Send message"
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        composer.addSubview(textField)
        composer.addSubview(sendButton)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: composer.topAnchor),
            separator.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            textField.topAnchor.constraint(equalTo: composer.topAnchor, constant: 8),
            textField.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 12),
            textField.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            textField.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -8),

            sendButton.leadingAnchor.constraint(equalTo: textField.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -12),
            sendButton.centerYAnchor.constraint(equalTo: textField.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 32),
            sendButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func configureLayout() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        messageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageView)

        // Follow the keyboard when it is up, but sit on the safe-area bottom when it is down.
        // The low-priority equality is the hidden-keyboard fallback.
        let keyboard = composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        keyboard.priority = UILayoutPriority(999)
        let safeBottom = composer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        safeBottom.priority = .defaultLow

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: composer.topAnchor),

            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboard,
            safeBottom,
            composer.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor),

            messageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                             constant: Theme.emptyStateTopInset),
            messageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            messageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            messageView.bottomAnchor.constraint(equalTo: composer.topAnchor),
        ])
    }

    private func configureNavigation() {
        navigationItem.rightBarButtonItem = usersItem
    }

    private func observeClient() {
        client.chatEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    // MARK: Events

    private func handle(_ event: ChatEvent) {
        switch event {
        case .joined(let name, let users) where name == room:
            self.users = users.sorted {
                $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
            }
            hasJoined = true
            messageView.isHidden = true
            tableView.isHidden = false
            textField.isEnabled = true
            sendButton.isEnabled = true
            updateUsersItem()

        case .userJoined(let name, let user) where name == room:
            if let index = users.firstIndex(where: {
                $0.username.caseInsensitiveCompare(user.username) == .orderedSame
            }) {
                users[index] = user
            } else {
                users.append(user)
                users.sort {
                    $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
                }
            }
            updateUsersItem()

        case .userLeft(let name, let username) where name == room:
            users.removeAll { $0.username.caseInsensitiveCompare(username) == .orderedSame }
            updateUsersItem()

        case .message(let message) where message.room == room:
            messages.append(message)
            tableView.insertRows(at: [IndexPath(row: messages.count - 1, section: 0)],
                                 with: .automatic)
            scrollToBottom()

        case .left(let name) where name == room:
            textField.isEnabled = false
            sendButton.isEnabled = false
            // The confirmation for a leave we requested ourselves needs no alert.
            guard !isLeaving else { return }
            presentAlert(title: "Left \(room)",
                         message: "The server removed you from this room.") { [weak self] in
                self?.navigationController?.popViewController(animated: true)
            }

        case .error(let text):
            let wasJoined = hasJoined
            presentAlert(title: wasJoined ? "Chat" : "Could not join \(room)",
                         message: text) { [weak self] in
                guard !wasJoined else { return }
                self?.navigationController?.popViewController(animated: true)
            }

        default:
            break
        }
    }

    // MARK: Actions

    @objc private func sendTapped() {
        sendCurrentText()
    }

    private func sendCurrentText() {
        guard let raw = textField.text, let text = ChatRules.normalizedMessage(raw) else { return }
        client.sendChatMessage(text, to: room)
        textField.text = ""
    }

    @objc private func showUsers() {
        guard !users.isEmpty else {
            presentAlert(title: "No Users", message: "Nobody else is in this room right now.")
            return
        }
        let controller = ChatRoomUsersViewController(room: room, users: users)
        navigationController?.pushViewController(controller, animated: true)
    }

    private func showJoining() {
        tableView.isHidden = true
        messageView.isHidden = false
        textField.isEnabled = false
        sendButton.isEnabled = false
        messageView.configure(title: "Joining \(room)…",
                              message: "Messages appear here as people talk.",
                              loading: true,
                              symbol: "bubble.left.and.bubble.right")
    }

    private func updateUsersItem() {
        usersItem.title = users.isEmpty ? "Users" : "Users (\(users.count))"
    }

    private func scrollToBottom() {
        guard !messages.isEmpty else { return }
        tableView.scrollToRow(at: IndexPath(row: messages.count - 1, section: 0),
                              at: .bottom, animated: true)
    }

    private func presentAlert(title: String, message: String, completion: (() -> Void)? = nil) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion?() })
        present(alert, animated: true)
    }
}

// MARK: - Table

extension ChatRoomViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ChatMessageCell.reuseIdentifier,
                                                 for: indexPath)
        (cell as? ChatMessageCell)?.configure(with: messages[indexPath.row])
        return cell
    }
}

// MARK: - Text field

extension ChatRoomViewController: UITextFieldDelegate {

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendCurrentText()
        return false
    }
}

// MARK: - Cell

private final class ChatMessageCell: UITableViewCell {

    static let reuseIdentifier = "ChatMessageCell"

    private static let maximumEnlargedEmojiCount = 6
    private static let enlargedEmojiPointSize: CGFloat = 40

    private let usernameLabel = UILabel()
    private let bodyLabel = WrappingLabel()
    private let stack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear

        contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 16,
                                                                      bottom: 4, trailing: 16)

        usernameLabel.font = .preferredFont(forTextStyle: .caption1)
        usernameLabel.adjustsFontForContentSizeCategory = true
        usernameLabel.textColor = .secondaryLabel
        usernameLabel.numberOfLines = 1

        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.textColor = .label

        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(usernameLabel)
        stack.addArrangedSubview(bodyLabel)
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(with message: ChatMessage) {
        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        bodyLabel.adjustsFontForContentSizeCategory = true

        switch message.kind {
        case .normal:
            usernameLabel.isHidden = false
            usernameLabel.text = message.username
            bodyLabel.text = message.text
            bodyLabel.textColor = .label
            bodyLabel.textAlignment = .natural
            if Self.isEmojiOnly(message.text) {
                bodyLabel.font = .systemFont(ofSize: Self.enlargedEmojiPointSize)
                bodyLabel.adjustsFontForContentSizeCategory = false
            } else {
                bodyLabel.font = bodyFont
            }

        case .action:
            usernameLabel.isHidden = true
            bodyLabel.text = "\(message.username) \(message.text)"
            bodyLabel.font = .italicSystemFont(ofSize: bodyFont.pointSize)
            bodyLabel.textColor = .secondaryLabel
            bodyLabel.textAlignment = .natural

        case .system:
            usernameLabel.isHidden = true
            bodyLabel.text = message.text
            bodyLabel.font = .preferredFont(forTextStyle: .footnote)
            bodyLabel.textColor = .tertiaryLabel
            bodyLabel.textAlignment = .center
        }
    }

    /// A short message made only of emoji is shown at a larger size. Whitespace between emoji is
    /// allowed; anything else (letters, punctuation, more than six emoji) keeps the normal size.
    private static func isEmojiOnly(_ text: String) -> Bool {
        let characters = Array(text.filter { !$0.isWhitespace })
        guard (1...maximumEnlargedEmojiCount).contains(characters.count) else { return false }
        return characters.allSatisfy(isEmoji)
    }

    private static func isEmoji(_ character: Character) -> Bool {
        let scalars = Array(character.unicodeScalars)
        guard !scalars.isEmpty else { return false }

        // ASCII digits, '#', and '*' carry the emoji property but are only emoji as part of a
        // keycap sequence ("1️⃣"), which has more than one scalar.
        if scalars.count == 1, let scalar = scalars.first, scalar.value < 0x80 { return false }

        let hasEmojiPresentation = scalars.contains { $0.properties.isEmojiPresentation }
        let hasVariationSelector = scalars.contains { $0.properties.isVariationSelector }
        let hasJoiner = scalars.contains { $0.value == 0x200D }
        let hasRegionalIndicator = scalars.contains { (0x1F1E6...0x1F1FF).contains($0.value) }
        let hasKeycap = scalars.contains { $0.value == 0x20E3 }
        let hasTag = scalars.contains { (0xE0020...0xE007F).contains($0.value) }

        guard hasEmojiPresentation || hasVariationSelector || hasJoiner
                || hasRegionalIndicator || hasKeycap || hasTag else {
            return false
        }

        return scalars.allSatisfy { scalar in
            scalar.properties.isEmoji
                || scalar.properties.isEmojiModifier
                || scalar.properties.isEmojiModifierBase
                || scalar.properties.isVariationSelector
                || scalar.value == 0x200D
                || (0xE0020...0xE007F).contains(scalar.value)
        }
    }
}
