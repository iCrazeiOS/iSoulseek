import Combine
import UIKit

/// Connection, account, sharing, activity log and known limitations.
final class SettingsViewController: UIViewController {

    // MARK: Rows

    private struct Item {
        enum Style {
            case value
            case subtitle
            case message
        }

        let title: String
        var subtitle: String?
        var value: String?
        var accessory: UITableViewCell.AccessoryType = .none
        var style: Style = .value
        var isDestructive = false
        var action: (() -> Void)?
    }

    private struct Section {
        let header: String?
        let footer: String?
        var items: [Item]
    }

    private let client: SoulseekClient
    private var cancellables = Set<AnyCancellable>()

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var sections: [Section] = []
    private var log: [String] = []

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
        title = "Settings"
        view.backgroundColor = .systemGroupedBackground

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        observeClient()
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Reflect any sort change made from the search screen.
        rebuild()
    }

    private func observeClient() {
        client.shares
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        client.listeningPort
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        client.stateChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        client.messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self else { return }
                self.log.insert(message, at: 0)
                if self.log.count > 20 { self.log.removeLast(self.log.count - 20) }
                self.rebuild()
            }
            .store(in: &cancellables)
    }

    // MARK: Building

    private func rebuild() {
        let store = client.store
        let snapshot = client.shares.value

        let connection = [
            Item(title: "Server", value: store.serverHost, accessory: .disclosureIndicator,
                 action: { [weak self] in self?.editServerHost() }),
            Item(title: "Server port", value: "\(store.serverPort)", accessory: .disclosureIndicator,
                 action: { [weak self] in self?.editServerPort() }),
            Item(title: "Preferred port", value: "\(store.preferredListeningPort)", accessory: .disclosureIndicator,
                 action: { [weak self] in self?.editListeningPort() }),
            Item(title: "Status", value: store.status.displayName, accessory: .disclosureIndicator,
                 action: { [weak self] in self?.chooseStatus() }),
            Item(title: "Active port", value: activePortText),
        ]

        let account = [
            Item(title: "Username", value: store.username.isEmpty ? "—" : store.username),
            Item(title: "Sign out", isDestructive: true, action: { [weak self] in self?.client.signOut() }),
        ]

        let search = [
            Item(title: "Sort results", value: store.defaultSearchSortOrder.displayName,
                 accessory: .disclosureIndicator, action: { [weak self] in self?.chooseSortOrder() }),
            Item(title: "Search filters", subtitle: store.defaultSearchOptions.summary,
                 accessory: .disclosureIndicator, style: .subtitle,
                 action: { [weak self] in self?.editSearchOptions() }),
        ]

        let startup = [
            Item(title: "Open on launch", value: store.startupTab.displayName,
                 accessory: .disclosureIndicator, action: { [weak self] in self?.chooseStartupTab() }),
        ]

        let shares = [
            Item(title: "Shared folder", subtitle: store.shareDirectory.path, style: .subtitle),
            Item(title: "Folders", value: "\(snapshot.folderCount)"),
            Item(title: "Files", value: "\(snapshot.fileCount)"),
            Item(title: "Rescan shares", accessory: .disclosureIndicator,
                 action: { [weak self] in self?.client.rescanShares() }),
        ]

        let activity = log.map { Item(title: $0, style: .message) }

        let limitations = [
            Item(title: "Transfers only run while iSoulseek is in the foreground. Inbound connections need a "
                    + "reachable port, so some transfers behind carrier-grade NAT will never start. This client "
                    + "does not take part in the distributed search network, so it does not answer other users' searches.",
                 style: .message),
        ]

        sections = [
            Section(header: "Connection", footer: nil, items: connection),
            Section(header: "Account", footer: nil, items: account),
            Section(header: "Startup",
                    footer: "The tab iSoulseek opens to, including from the Home Screen icon's "
                        + "quick actions.",
                    items: startup),
            Section(header: "Search results",
                    footer: "Applied to every search. You can also change these from the search screen.",
                    items: search),
            Section(header: "Shares",
                    footer: "Anything placed in this folder is shared with every user who browses you. "
                        + "The folder is visible in the Files app under On My iPhone ▸ iSoulseek ▸ Shared.",
                    items: shares),
            Section(header: "Activity", footer: nil, items: activity),
            Section(header: "Limitations", footer: nil, items: limitations),
        ]
        tableView.reloadData()
    }

    private var activePortText: String {
        let port = client.listeningPort.value
        return port == 0 ? "Inactive" : "\(port)"
    }

    // MARK: Actions

    private func editServerHost() {
        promptForText(title: "Server", message: "Soulseek server host name.",
                      current: client.store.serverHost, keyboard: .URL) { [weak self] text in
            guard let self, let text, !text.isEmpty else { return }
            self.client.store.serverHost = text
            self.rebuild()
        }
    }

    private func editServerPort() {
        promptForText(title: "Server port", message: "Usually 2242.",
                      current: "\(client.store.serverPort)", keyboard: .numberPad) { [weak self] text in
            guard let self, let text, let port = UInt16(text) else { return }
            self.client.store.serverPort = port
            self.rebuild()
        }
    }

    private func editListeningPort() {
        promptForText(title: "Preferred port", message: "Used for inbound connections. Applies on reconnect.",
                      current: "\(client.store.preferredListeningPort)", keyboard: .numberPad) { [weak self] text in
            guard let self, let text, let port = UInt16(text) else { return }
            self.client.store.preferredListeningPort = port
            self.rebuild()
        }
    }

    private func chooseStatus() {
        let alert = UIAlertController(title: "Status", message: nil, preferredStyle: .actionSheet)
        for status in [UserStatus.online, .away] {
            alert.addAction(UIAlertAction(title: status.displayName, style: .default) { [weak self] _ in
                self?.client.setStatus(status)
                self?.rebuild()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        Theme.configurePopover(alert, in: tableView)
        present(alert, animated: true)
    }

    private func chooseSortOrder() {
        let alert = UIAlertController(title: "Sort results",
                                      message: "How search results are ordered.",
                                      preferredStyle: .actionSheet)
        for order in SearchSortOrder.allCases {
            let title = order == client.store.defaultSearchSortOrder ? "✓ \(order.displayName)" : order.displayName
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.client.store.setDefaultSearchSortOrder(order)
                self?.rebuild()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        Theme.configurePopover(alert, in: tableView)
        present(alert, animated: true)
    }

    private func chooseStartupTab() {
        let alert = UIAlertController(title: "Startup tab",
                                      message: "The tab iSoulseek opens to.",
                                      preferredStyle: .actionSheet)
        for tab in AppTab.allCases {
            let title = tab == client.store.startupTab ? "✓ \(tab.displayName)" : tab.displayName
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.client.store.startupTab = tab
                self?.rebuild()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        Theme.configurePopover(alert, in: tableView)
        present(alert, animated: true)
    }

    private func editSearchOptions() {
        let controller = SearchOptionsViewController(options: client.store.defaultSearchOptions) { [weak self] options in
            self?.client.store.setDefaultSearchOptions(options)
            self?.rebuild()
        }
        present(controller, animated: true)
    }

    private func promptForText(title: String, message: String?, current: String,
                               keyboard: UIKeyboardType, completion: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = current
            field.keyboardType = keyboard
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak alert] _ in
            completion(alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines))
        })
        present(alert, animated: true)
    }
}

// MARK: - UITableViewDataSource

extension SettingsViewController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].header
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        makeCell(for: sections[indexPath.section].items[indexPath.row])
    }

    private func makeCell(for item: Item) -> UITableViewCell {
        switch item.style {
        case .value:
            let cell = tableView.dequeueReusableCell(withIdentifier: "value")
                ?? UITableViewCell(style: .value1, reuseIdentifier: "value")
            cell.textLabel?.text = item.title
            cell.textLabel?.font = .preferredFont(forTextStyle: .body)
            cell.textLabel?.adjustsFontForContentSizeCategory = true
            cell.textLabel?.textColor = item.isDestructive ? .systemRed : .label
            cell.detailTextLabel?.text = item.value
            cell.accessoryType = item.accessory
            cell.selectionStyle = item.action == nil ? .none : .default
            return cell

        case .subtitle:
            let cell = tableView.dequeueReusableCell(withIdentifier: "subtitle")
                ?? UITableViewCell(style: .subtitle, reuseIdentifier: "subtitle")
            cell.textLabel?.text = item.title
            cell.textLabel?.font = .preferredFont(forTextStyle: .body)
            cell.textLabel?.adjustsFontForContentSizeCategory = true
            cell.textLabel?.textColor = .label
            cell.detailTextLabel?.text = item.subtitle
            cell.detailTextLabel?.font = .preferredFont(forTextStyle: .caption1)
            cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.detailTextLabel?.numberOfLines = 0
            cell.accessoryType = item.accessory
            cell.selectionStyle = item.action == nil ? .none : .default
            return cell

        case .message:
            let cell = tableView.dequeueReusableCell(withIdentifier: "message")
                ?? UITableViewCell(style: .default, reuseIdentifier: "message")
            cell.textLabel?.text = item.title
            cell.textLabel?.font = .preferredFont(forTextStyle: .footnote)
            cell.textLabel?.adjustsFontForContentSizeCategory = true
            cell.textLabel?.textColor = .secondaryLabel
            cell.textLabel?.numberOfLines = 0
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }
    }
}

// MARK: - UITableViewDelegate

extension SettingsViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        sections[indexPath.section].items[indexPath.row].action?()
    }
}
