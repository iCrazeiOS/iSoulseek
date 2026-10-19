import Combine
import UIKit

/// Search the network. Incoming results are coalesced before the table is updated.
final class SearchViewController: UIViewController {

    // MARK: Types

    private struct Item: Hashable {
        let id: Int
        let result: SearchResult
    }

    private struct UserSection {
        let displayName: String
        var items: [Item]
    }

    private static let maximumResults = 5000
    private static let flushInterval: TimeInterval = 0.25

    // MARK: State

    private let client: SoulseekClient
    private var cancellables = Set<AnyCancellable>()

    private var sectionsByKey: [String: UserSection] = [:]
    private var order: [String] = []
    private var pendingResults: [SearchResult] = []
    private var flushWorkItem: DispatchWorkItem?
    private var nextItemID = 0
    private var displayedCount = 0
    private var isCapped = false
    private var hasSearched = false
    private var activeToken: UInt32?

    // MARK: Views

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let messageView = MessageView()
    private let statusLabel = UILabel()

    private lazy var searchController: UISearchController = {
        let controller = UISearchController(searchResultsController: nil)
        controller.obscuresBackgroundDuringPresentation = false
        controller.searchBar.placeholder = "Artist, album or file name"
        controller.searchBar.autocapitalizationType = .none
        controller.searchBar.autocorrectionType = .no
        controller.searchBar.delegate = self
        return controller
    }()

    private lazy var dataSource: UITableViewDiffableDataSource<String, Item> = {
        UITableViewDiffableDataSource(tableView: tableView) { tableView, indexPath, item in
            let cell = tableView.dequeueReusableCell(withIdentifier: SearchResultCell.reuseIdentifier,
                                                     for: indexPath)
            (cell as? SearchResultCell)?.configure(with: item.result)
            return cell
        }
    }()

    private lazy var statusItem = UIBarButtonItem(customView: statusLabel)
    private lazy var cancelItem = UIBarButtonItem(title: "Cancel", style: .plain,
                                                  target: self, action: #selector(cancelSearch))

    init(client: SoulseekClient) {
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
        title = "Search"
        view.backgroundColor = .systemBackground

        configureTable()
        configureNavigation()
        observeClient()
        updateBackground()
        updateToolbar()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    private func configureTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = dataSource
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 76
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.estimatedSectionHeaderHeight = 44
        tableView.keyboardDismissMode = .onDrag
        tableView.register(SearchResultCell.self, forCellReuseIdentifier: SearchResultCell.reuseIdentifier)
        tableView.register(SearchSectionHeader.self,
                           forHeaderFooterViewReuseIdentifier: SearchSectionHeader.reuseIdentifier)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureNavigation() {
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Browse user…", style: .plain,
                                                            target: self, action: #selector(promptForUsername))

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.lineBreakMode = .byTruncatingTail
    }

    private func observeClient() {
        client.searchResults
            .receive(on: DispatchQueue.main)
            .sink { [weak self] result in self?.enqueue(result) }
            .store(in: &cancellables)

        client.searchFinished
            .receive(on: DispatchQueue.main)
            .sink { [weak self] token in self?.finishSearch(token) }
            .store(in: &cancellables)
    }

    // MARK: Searching

    @objc private func cancelSearch() {
        guard let token = activeToken else { return }
        client.cancelSearch(token)
    }

    private func startSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.count <= SoulseekClient.maximumQueryLength else {
            presentAlert(title: "Search is too long",
                         message: "Keep the query under \(SoulseekClient.maximumQueryLength) characters.")
            return
        }

        if let token = activeToken { client.cancelSearch(token) }
        resetResults()
        hasSearched = true

        guard let token = client.search(trimmed) else {
            presentAlert(title: "Cannot search", message: "Enter a search term.")
            return
        }
        activeToken = token
        updateBackground()
        updateToolbar()
    }

    private func finishSearch(_ token: UInt32) {
        guard token == activeToken else { return }
        activeToken = nil
        flushNow()
        updateBackground()
        updateToolbar()
    }

    private func resetResults() {
        activeToken = nil
        sectionsByKey.removeAll()
        order.removeAll()
        pendingResults.removeAll()
        flushWorkItem?.cancel()
        flushWorkItem = nil
        displayedCount = 0
        isCapped = false
        applySnapshot()
    }

    // MARK: Coalescing

    private func enqueue(_ result: SearchResult) {
        guard result.token == activeToken else { return }
        guard displayedCount < Self.maximumResults else {
            if !isCapped {
                isCapped = true
                updateToolbar()
            }
            return
        }
        pendingResults.append(result)
        displayedCount += 1
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.flushNow() }
        flushWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushInterval, execute: work)
    }

    private func flushNow() {
        flushWorkItem?.cancel()
        flushWorkItem = nil
        applyPending()
    }

    private func applyPending() {
        guard !pendingResults.isEmpty else { return }
        let incoming = pendingResults
        pendingResults.removeAll()

        for result in incoming {
            let key = result.username.lowercased()
            let item = Item(id: nextItemID, result: result)
            nextItemID += 1
            if var section = sectionsByKey[key] {
                section.items.append(item)
                sectionsByKey[key] = section
            } else {
                sectionsByKey[key] = UserSection(displayName: result.username, items: [item])
                order.insert(key, at: 0)
            }
        }
        applySnapshot()
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<String, Item>()
        snapshot.appendSections(order)
        for key in order {
            if let section = sectionsByKey[key] {
                snapshot.appendItems(section.items, toSection: key)
            }
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        updateBackground()
        updateToolbar()
    }

    private func updateBackground() {
        let total = order.reduce(0) { $0 + (sectionsByKey[$1]?.items.count ?? 0) }
        guard total == 0 else {
            tableView.backgroundView = nil
            return
        }
        if activeToken != nil {
            messageView.configure(title: "Searching…", message: "Results appear as peers respond.", loading: true)
        } else if hasSearched {
            messageView.configure(title: "No results",
                                  message: "Try different words, or browse a specific user.")
        } else {
            messageView.configure(title: "Find music",
                                  message: "Search the network by artist, album or file name.")
        }
        tableView.backgroundView = messageView
    }

    private func updateToolbar() {
        if activeToken != nil {
            statusLabel.text = isCapped
                ? "Searching… \(displayedCount.formatted()) results (capped)"
                : "Searching… \(displayedCount.formatted()) results"
        } else if displayedCount > 0 {
            statusLabel.text = isCapped
                ? "\(displayedCount.formatted()) results (showing first \(Self.maximumResults.formatted()))"
                : "\(displayedCount.formatted()) results"
        } else {
            statusLabel.text = "Search the network"
        }

        var items: [UIBarButtonItem] = [statusItem, .flexibleSpace()]
        if activeToken != nil { items.append(cancelItem) }
        setToolbarItems(items, animated: false)
    }

    // MARK: Actions

    private func download(_ result: SearchResult) {
        client.download(username: result.username, filename: result.file.name, size: result.file.size) { [weak self] transfer in
            guard let self else { return }
            if transfer == nil {
                Theme.showToast("Could not download \(result.file.name)", in: self.view)
            } else {
                Theme.showToast("Added \(result.file.name) to downloads", in: self.view)
            }
        }
    }

    @objc private func promptForUsername() {
        let alert = UIAlertController(title: "Browse a user",
                                      message: "Enter a Soulseek username.",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Username"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Browse", style: .default) { [weak self, weak alert] _ in
            let name = (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            self?.pushBrowse(username: name)
        })
        present(alert, animated: true)
    }

    private func presentActions(for result: SearchResult, at indexPath: IndexPath) {
        let alert = UIAlertController(title: result.file.name, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Download", style: .default) { [weak self] _ in
            self?.download(result)
        })
        alert.addAction(UIAlertAction(title: "Browse \(result.username)", style: .default) { [weak self] _ in
            self?.pushBrowse(username: result.username)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        Theme.configurePopover(alert, in: tableView, rect: tableView.rectForRow(at: indexPath))
        present(alert, animated: true)
    }

    private func pushBrowse(username: String) {
        guard let navigation = navigationController else { return }
        navigation.pushViewController(BrowseViewController(username: username, client: client), animated: true)
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - UITableViewDelegate

extension SearchViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let key = dataSource.sectionIdentifier(for: section),
              let model = sectionsByKey[key] else { return nil }
        let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: SearchSectionHeader.reuseIdentifier) as? SearchSectionHeader
        header?.configure(username: model.displayName, count: model.items.count)
        header?.onBrowse = { [weak self] in self?.pushBrowse(username: model.displayName) }
        return header
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        presentActions(for: item.result, at: indexPath)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let action = UIContextualAction(style: .normal, title: "Download") { [weak self] _, _, completion in
            self?.download(item.result)
            completion(true)
        }
        action.backgroundColor = .systemBlue
        return UISwipeActionsConfiguration(actions: [action])
    }
}

// MARK: - UISearchBarDelegate

extension SearchViewController: UISearchBarDelegate {

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        startSearch(searchBar.text ?? "")
    }
}

// MARK: - SearchResultCell

private final class SearchResultCell: UITableViewCell {

    static let reuseIdentifier = "SearchResultCell"

    private let titleLabel = UILabel()
    private let folderLabel = UILabel()
    private let metaLabel = UILabel()
    private let badge = BadgeLabel()
    private let texts = UIStackView()
    private let trailing = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(with result: SearchResult) {
        titleLabel.text = result.file.name
        folderLabel.text = folderText(for: result)
        metaLabel.text = metaText(for: result)
        configureBadge(for: result)
        accessibilityIdentifier = "search.result"
    }

    private func folderText(for result: SearchResult) -> String {
        let components = ShareFolder.components(of: result.fullPath)
        let folders = components.dropLast()
        return folders.isEmpty ? "Shared" : folders.joined(separator: " / ")
    }

    private func metaText(for result: SearchResult) -> String {
        var parts = [Formatters.bytes(result.file.size)]
        if let bitrate = result.file.bitrate, bitrate > 0 { parts.append("\(bitrate) kbps") }
        if let duration = result.file.duration, duration > 0 { parts.append(Formatters.duration(duration)) }
        if result.averageSpeed > 0 { parts.append(Formatters.speed(UInt64(result.averageSpeed))) }
        return parts.joined(separator: "  ·  ")
    }

    private func configureBadge(for result: SearchResult) {
        if result.isSlotFree {
            badge.isHidden = false
            badge.text = "Free slot"
            badge.textColor = .systemGreen
            badge.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.16)
        } else if result.queueLength > 0 {
            badge.isHidden = false
            badge.text = "Queue \(result.queueLength)"
            badge.textColor = .systemOrange
            badge.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.16)
        } else {
            badge.isHidden = true
        }
    }

    private func setup() {
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingMiddle

        folderLabel.font = .preferredFont(forTextStyle: .caption1)
        folderLabel.adjustsFontForContentSizeCategory = true
        folderLabel.textColor = .secondaryLabel
        folderLabel.numberOfLines = 1
        folderLabel.lineBreakMode = .byTruncatingMiddle

        metaLabel.font = .preferredFont(forTextStyle: .caption1)
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.textColor = .tertiaryLabel
        metaLabel.numberOfLines = 1

        badge.font = .preferredFont(forTextStyle: .caption2)
        badge.adjustsFontForContentSizeCategory = true
        badge.layer.cornerRadius = 6
        badge.layer.cornerCurve = .continuous
        badge.clipsToBounds = true

        texts.axis = .vertical
        texts.spacing = 2
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        texts.addArrangedSubview(titleLabel)
        texts.addArrangedSubview(folderLabel)
        texts.addArrangedSubview(metaLabel)

        trailing.axis = .vertical
        trailing.alignment = .trailing
        trailing.spacing = 4
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.addArrangedSubview(badge)

        let row = UIStackView(arrangedSubviews: [texts, trailing])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }
}

// MARK: - SearchSectionHeader

private final class SearchSectionHeader: UITableViewHeaderFooterView {

    static let reuseIdentifier = "SearchSectionHeader"

    var onBrowse: (() -> Void)?

    private let nameLabel = UILabel()
    private let countLabel = UILabel()
    private let browseButton = UIButton(type: .system)

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(username: String, count: Int) {
        nameLabel.text = username
        countLabel.text = count == 1 ? "1 result" : "\(count.formatted()) results"
    }

    private func setup() {
        contentView.backgroundColor = .secondarySystemBackground

        nameLabel.font = .preferredFont(forTextStyle: .subheadline)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingMiddle

        countLabel.font = .preferredFont(forTextStyle: .caption1)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = .secondaryLabel

        browseButton.setTitle("Browse", for: .normal)
        browseButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        browseButton.addTarget(self, action: #selector(browseTapped), for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [nameLabel, countLabel, browseButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        browseButton.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }

    @objc private func browseTapped() {
        onBrowse?()
    }
}
