import Combine
import UIKit

/// The Chat tab: public rooms plus the rooms this session has joined.
final class ChatRoomsViewController: UIViewController {

    private struct Section {
        let title: String?
        let rooms: [ChatRoom]
    }

    private enum RoomSortOrder: Int, CaseIterable {
        case name
        case mostPeople
        case leastPeople

        var displayName: String {
            switch self {
            case .name: return "A–Z"
            case .mostPeople: return "Most People"
            case .leastPeople: return "Least People"
            }
        }
    }

    private let client: SoulseekClient
    private var cancellables = Set<AnyCancellable>()

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let searchBar = UISearchBar()
    private let messageView = MessageView()
    private let refreshControl = UIRefreshControl()

    private var rooms: [ChatRoom] = []
    private var joinedNames: [String] = []
    private var hasLoaded = false
    private var sortOrder: RoomSortOrder = .name

    private lazy var sortItem = UIBarButtonItem(image: nil, style: .plain,
                                                target: nil, action: nil)

    private var filterText: String {
        (searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleRooms: [ChatRoom] {
        guard !filterText.isEmpty else { return rooms }
        return rooms.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
    }

    private var visibleJoinedNames: [String] {
        guard !filterText.isEmpty else { return joinedNames }
        return joinedNames.filter { $0.localizedCaseInsensitiveContains(filterText) }
    }

    private var sections: [Section] {
        let matchingRooms = visibleRooms
        let matchingJoined = visibleJoinedNames
        let joined = sorted(matchingJoined.map { name in
            matchingRooms.first { $0.name == name }
                ?? rooms.first { $0.name == name }
                ?? ChatRoom(name: name, userCount: 0)
        })
        let others = sorted(matchingRooms.filter { room in
            !matchingJoined.contains { $0.caseInsensitiveCompare(room.name) == .orderedSame }
        })

        var sections: [Section] = []
        if !joined.isEmpty {
            sections.append(Section(title: "Joined", rooms: joined))
        }
        if !others.isEmpty {
            sections.append(Section(title: joined.isEmpty ? nil : "Public Rooms", rooms: others))
        }
        return sections
    }

    private func sorted(_ rooms: [ChatRoom]) -> [ChatRoom] {
        switch sortOrder {
        case .name:
            return rooms.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .mostPeople:
            return rooms.sorted {
                if $0.userCount != $1.userCount { return $0.userCount > $1.userCount }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .leastPeople:
            return rooms.sorted {
                if $0.userCount != $1.userCount { return $0.userCount < $1.userCount }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

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
        title = "Chat"
        view.backgroundColor = .systemBackground

        configureSearchBar()
        configureTable()
        configureLayout()
        configureNavigation()
        observeClient()
        requestRooms()
        updateBackground()
    }

    // MARK: Setup

    private func configureSearchBar() {
        searchBar.placeholder = "Search rooms"
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.returnKeyType = .done
        searchBar.searchBarStyle = .minimal
        searchBar.delegate = self
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "RoomCell")

        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        tableView.refreshControl = refreshControl
    }

    private enum SearchBarPadding {
        static let horizontal: CGFloat = 12
        static let vertical: CGFloat = 10
    }

    private func configureLayout() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        messageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageView)

        // Added last so it stays above the empty-state overlay.
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchBar)

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                           constant: -SearchBarPadding.vertical),
            searchBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                                               constant: SearchBarPadding.horizontal),
            searchBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                                                constant: -SearchBarPadding.horizontal),

            // The bar also pads below its field, so add that back to keep the list where it was.
            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor,
                                           constant: SearchBarPadding.vertical),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            messageView.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 16),
            messageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            messageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            messageView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func configureNavigation() {
        navigationItem.leftBarButtonItem = sortItem

        let joinItem = UIBarButtonItem(image: UIImage(systemName: "plus.bubble"),
                                       style: .plain,
                                       target: self,
                                       action: #selector(promptForRoom))
        joinItem.accessibilityLabel = "Join a chat room"
        navigationItem.rightBarButtonItem = joinItem

        updateSortMenu()
    }

    private func updateSortMenu() {
        sortItem.image = UIImage(systemName: "arrow.up.arrow.down")
        sortItem.accessibilityLabel = "Sort rooms"
        sortItem.menu = UIMenu(children: RoomSortOrder.allCases.map { order in
            UIAction(title: order.displayName, state: sortOrder == order ? .on : .off) { [weak self] _ in
                self?.setSortOrder(order)
            }
        })
    }

    private func setSortOrder(_ order: RoomSortOrder) {
        sortOrder = order
        updateSortMenu()
        tableView.reloadData()
    }

    private func observeClient() {
        client.chatRoomList
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rooms in
                guard let self else { return }
                self.rooms = rooms.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                if !rooms.isEmpty { self.hasLoaded = true }
                self.refreshControl.endRefreshing()
                self.tableView.reloadData()
                self.updateBackground()
            }
            .store(in: &cancellables)

        client.joinedRooms
            .receive(on: DispatchQueue.main)
            .sink { [weak self] names in
                guard let self else { return }
                self.joinedNames = names
                self.tableView.reloadData()
                self.updateBackground()
            }
            .store(in: &cancellables)
    }

    // MARK: Actions

    private func requestRooms() {
        client.requestRoomList()
        // The server has no request/response id for the room list, so stop the spinner on a timer
        // rather than leaving it spinning forever if the request is ignored.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.refreshControl.endRefreshing()
            self.hasLoaded = true
            self.updateBackground()
        }
    }

    @objc private func refresh() {
        requestRooms()
    }

    private func clearFilter() {
        searchBar.text = ""
        searchBar.resignFirstResponder()
        tableView.reloadData()
        updateBackground()
    }

    @objc private func promptForRoom() {
        let alert = UIAlertController(title: "Join a Chat Room",
                                      message: "Enter a room name. Joining a new name creates it.",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Room name"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Join", style: .default) { [weak self, weak alert] _ in
            guard let self, let raw = alert?.textFields?.first?.text else { return }
            guard let name = ChatRules.normalizedRoomName(raw) else {
                self.presentAlert(title: "Invalid Room Name",
                                  message: "Use 1–24 printable characters, with no leading, trailing or double spaces.")
                return
            }
            self.open(name)
        })
        present(alert, animated: true)
    }

    private func open(_ name: String) {
        let controller = ChatRoomViewController(room: name, client: client)
        navigationController?.pushViewController(controller, animated: true)
    }

    private func updateBackground() {
        let hasContent = !sections.isEmpty
        tableView.isHidden = !hasContent
        messageView.isHidden = hasContent
        guard !hasContent else { return }

        if !hasLoaded {
            messageView.configure(title: "Loading rooms…",
                                  loading: true,
                                  symbol: "bubble.left.and.bubble.right")
        } else if !filterText.isEmpty {
            messageView.configure(title: "No matching rooms",
                                  message: "Try a different name, or use + to join a room.",
                                  actionTitle: "Clear Search",
                                  onAction: { [weak self] in self?.clearFilter() },
                                  symbol: "magnifyingglass")
        } else {
            messageView.configure(title: "No chat rooms",
                                  message: "Pull to refresh, or join a room by name.",
                                  actionTitle: "Refresh",
                                  onAction: { [weak self] in self?.requestRooms() },
                                  symbol: "bubble.left.and.bubble.right")
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Table

extension ChatRoomsViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rooms.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "RoomCell", for: indexPath)
        let room = sections[indexPath.section].rooms[indexPath.row]
        let isJoined = joinedNames.contains { $0.caseInsensitiveCompare(room.name) == .orderedSame }

        var content = UIListContentConfiguration.subtitleCell()
        content.text = room.name
        content.secondaryText = room.userCount == 1
            ? "1 user" + (isJoined ? " · Joined" : "")
            : "\(room.userCount) users" + (isJoined ? " · Joined" : "")
        content.image = UIImage(systemName: isJoined ? "bubble.left.fill" : "bubble.left")
        content.imageProperties.tintColor = isJoined ? .systemBlue : .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        open(sections[indexPath.section].rooms[indexPath.row].name)
    }
}

// MARK: - Search

extension ChatRoomsViewController: UISearchBarDelegate {

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        tableView.reloadData()
        updateBackground()
    }

    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(true, animated: true)
    }

    func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(false, animated: true)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        clearFilter()
    }
}
