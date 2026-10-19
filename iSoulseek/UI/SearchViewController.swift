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
    private var visibleCount = 0
    private var isCapped = false
    private var hasSearched = false
    private var activeToken: UInt32?
    private var sortOrder: SearchSortOrder = .arrival
    private var showsCancelButton = false

    // MARK: Views

    private let tableView = UITableView(frame: .zero, style: .plain)

    /// A plain search bar rather than `UISearchController`. Building against the iOS 27 SDK breaks
    /// iOS-on-Mac ("Designed for iPad"): activating a navigation-item search controller runs
    /// `_UISearchPresentationController`, which asks `UINavigationBar` for its default height and
    /// reaches `UIScreen`'s scene bounds — now an unsupported focus path that throws
    /// "Accessing the focus system through UIScreen is no longer supported." Keeping the search bar
    /// in the content view sidesteps the presentation machinery entirely.
    private let searchBar = UISearchBar()
    private let messageView = MessageView()
    private let statusLabel = UILabel()
    private let statusRow = UIView()

    private lazy var dataSource: UITableViewDiffableDataSource<String, Item> = {
        UITableViewDiffableDataSource(tableView: tableView) { tableView, indexPath, item in
            let cell = tableView.dequeueReusableCell(withIdentifier: SearchResultCell.reuseIdentifier,
                                                     for: indexPath)
            (cell as? SearchResultCell)?.configure(with: item.result)
            return cell
        }
    }()

    private lazy var sortItem = UIBarButtonItem(image: nil, style: .plain,
                                                target: nil, action: nil)
    private lazy var browseItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "person.wave.2.fill"),
                                   style: .plain,
                                   target: self,
                                   action: #selector(promptForUsername))
        item.accessibilityLabel = "Search user"
        return item
    }()

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
        sortOrder = client.store.searchSortOrder

        configureSearchBar()
        configureTable()
        configureLayout()
        configureNavigation()
        observeClient()
        updateSortMenu()
        updateBackground()
        updateStatus()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Pick up changes made from Settings while this tab was away.
        let stored = client.store.searchSortOrder
        if stored != sortOrder {
            sortOrder = stored
            updateSortMenu()
            applySnapshot()
        }
    }

    private func configureSearchBar() {
        searchBar.placeholder = "Artist, album or file name"
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.returnKeyType = .search
        searchBar.searchBarStyle = .minimal
        searchBar.delegate = self
    }

    private func configureTable() {
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
    }

    /// A plain label rather than a bar button item, so it does not take on the interactive
    /// "Liquid Glass" styling of the toolbar and cannot be mistaken for a control.
    private func configureLayout() {
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.8
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusRow.addSubview(statusLabel)
        statusRow.isHidden = true

        // The search bar is inset from the screen edges, the way the system search bar
        // sits inside a navigation bar, rather than running the full width of the display.
        searchBar.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [statusRow, tableView])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        // An overlay rather than the table's `backgroundView`, so the empty state is centred in
        // the same area as the Downloads tab's (above the safe area's bottom edge) instead of
        // halfway down the table's full height.
        messageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageView)

        // Added last so it stays above the empty-state overlay: the overlay starts above the
        // search bar's bottom edge, and a plain view would otherwise swallow taps on the bar.
        view.addSubview(searchBar)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: statusRow.topAnchor, constant: 2),
            statusLabel.leadingAnchor.constraint(equalTo: statusRow.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: statusRow.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: -8),

            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            stack.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            messageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                             constant: Theme.emptyStateTopInset),
            messageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            messageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            messageView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func configureNavigation() {
        navigationItem.leftBarButtonItem = sortItem
        navigationItem.rightBarButtonItem = browseItem
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
        updateStatus()
    }

    private func finishSearch(_ token: UInt32) {
        guard token == activeToken else { return }
        activeToken = nil
        flushNow()
        updateBackground()
        updateStatus()
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
                updateStatus()
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
        // Order each user's results, then order the sections themselves.
        var visible: [String: [Item]] = [:]
        for key in order {
            guard let section = sectionsByKey[key] else { continue }
            visible[key] = sorted(section.items)
        }

        var keys = order.filter { visible[$0] != nil }
        if sortOrder != .arrival {
            keys.sort { lhs, rhs in
                guard let left = visible[lhs]?.first, let right = visible[rhs]?.first else { return false }
                if sortOrder.isOrderedBefore(left.result, right.result) { return true }
                if sortOrder.isOrderedBefore(right.result, left.result) { return false }
                return left.id < right.id
            }
        }

        var snapshot = NSDiffableDataSourceSnapshot<String, Item>()
        snapshot.appendSections(keys)
        for key in keys {
            snapshot.appendItems(visible[key] ?? [], toSection: key)
        }

        visibleCount = keys.reduce(0) { $0 + (visible[$1]?.count ?? 0) }
        dataSource.apply(snapshot, animatingDifferences: false)
        updateBackground()
        updateStatus()
    }

    private func sorted(_ items: [Item]) -> [Item] {
        guard sortOrder != .arrival else { return items }
        return items.sorted { lhs, rhs in
            if sortOrder.isOrderedBefore(lhs.result, rhs.result) { return true }
            if sortOrder.isOrderedBefore(rhs.result, lhs.result) { return false }
            return lhs.id < rhs.id
        }
    }

    private func updateBackground() {
        guard visibleCount == 0 else {
            messageView.isHidden = true
            return
        }
        if activeToken != nil {
            messageView.configure(title: "Searching…", message: "Results appear as peers respond.", loading: true)
        } else if hasSearched {
            messageView.configure(title: "No results",
                                  message: "Try different words, or browse a specific user.",
                                  symbol: "music.note.list")
        } else {
            messageView.configure(title: "Find music",
                                  message: "Search the network by artist, album or file name.",
                                  symbol: "magnifyingglass")
        }
        messageView.isHidden = false
    }

    private func updateStatus() {
        let text: String?
        if activeToken != nil {
            text = isCapped
                ? "Searching… \(visibleCount.formatted()) shown (capped)"
                : "Searching… \(visibleCount.formatted()) shown"
        } else if visibleCount > 0 {
            text = isCapped
                ? "\(visibleCount.formatted()) shown (first \(Self.maximumResults.formatted()))"
                : "\(visibleCount.formatted()) results"
        } else {
            text = nil
        }

        statusLabel.text = text
        statusRow.isHidden = (text == nil)
        updateCancelButton()
    }

    /// The search bar's own cancel button doubles as "stop this search", so it stays visible while a
    /// query is running even after the keyboard is dismissed.
    private func updateCancelButton() {
        let visible = searchBar.isFirstResponder || activeToken != nil
        guard visible != showsCancelButton else { return }
        showsCancelButton = visible
        searchBar.setShowsCancelButton(visible, animated: true)
    }

    // MARK: Options

    private func updateSortMenu() {
        sortItem.image = UIImage(systemName: "arrow.up.arrow.down")
        sortItem.accessibilityLabel = "Sort results"
        sortItem.menu = UIMenu(children: SearchSortOrder.allCases.map { order in
            UIAction(title: order.displayName, state: sortOrder == order ? .on : .off) { [weak self] _ in
                self?.setSortOrder(order)
            }
        })
    }

    private func setSortOrder(_ order: SearchSortOrder) {
        sortOrder = order
        client.store.searchSortOrder = order
        updateSortMenu()
        applySnapshot()
    }

    // MARK: Actions

    private func download(_ result: SearchResult) {
        client.download(username: result.username, filename: result.file.name, size: result.file.size) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .added:
                Theme.showToast("Added \(result.file.name) to downloads", in: self.view)
            case .alreadyDownloading:
                Theme.showToast("Already downloading \(result.file.name)", in: self.view)
            case .alreadyDownloaded:
                Theme.showToast("Already downloaded \(result.file.name)", in: self.view)
            case nil:
                Theme.showToast("Could not download \(result.file.name)", in: self.view)
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
            self?.pushBrowse(username: result.username, folder: result.folderPath)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        Theme.configurePopover(alert, in: tableView, rect: tableView.rectForRow(at: indexPath))
        present(alert, animated: true)
    }

    private func pushBrowse(username: String, folder: String? = nil) {
        guard let navigation = navigationController else { return }
        let browse = BrowseViewController(username: username, client: client, focusedFolder: folder)
        navigation.pushViewController(browse, animated: true)
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
        let download = UIContextualAction(style: .normal, title: "Download") { [weak self] _, _, completion in
            self?.download(item.result)
            completion(true)
        }
        download.backgroundColor = .systemBlue
        let browse = UIContextualAction(style: .normal, title: "Browse") { [weak self] _, _, completion in
            self?.pushBrowse(username: item.result.username, folder: item.result.folderPath)
            completion(true)
        }
        browse.backgroundColor = .systemGray
        return UISwipeActionsConfiguration(actions: [download, browse])
    }
}

// MARK: - UISearchBarDelegate

extension SearchViewController: UISearchBarDelegate {

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        startSearch(searchBar.text ?? "")
        searchBar.resignFirstResponder()
    }

    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        updateCancelButton()
    }

    func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
        updateCancelButton()
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.text = ""
        searchBar.resignFirstResponder()
        if let token = activeToken { client.cancelSearch(token) }
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
        // The badge must keep its natural width; the title truncates instead.
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

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
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
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

    private let nameLabel = UILabel()
    private let countLabel = UILabel()

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

        let row = UIStackView(arrangedSubviews: [nameLabel, countLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }
}
