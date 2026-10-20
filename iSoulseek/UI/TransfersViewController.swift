import Combine
import QuickLook
import UIKit

/// Transfers, split into "Downloading" (active downloads), "Downloaded" (files on disk) and
/// "Uploading" (files other users are taking from the share).
final class TransfersViewController: UIViewController {

    private enum Item {
        case transfer(Transfer)
        case file(DownloadedFile, depth: Int)
        case folder(DownloadFolder, depth: Int)
    }

    private let client: SoulseekClient
    private var cancellables = Set<AnyCancellable>()

    private let tabControl = UISegmentedControl(items: ["Downloading", "Downloaded", "Uploading"])
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let messageView = MessageView()

    private var transfers: [Transfer] = []
    private var downloadedFiles: [DownloadedFile] = []
    private var displayed: [Item] = []
    private var scanScheduled = false
    private var scanGeneration = 0
    private var previewURL: URL?
    private var sortOrder: DownloadSortOrder = .newest
    private var layout: DownloadLayout = .list
    private var expandedFolders: Set<String> = []

    private var isSelecting = false
    private var isDeleting = false
    private var selectedTransfers: Set<UInt32> = []
    private var selectedFiles: Set<URL> = []

    private var currentTab: TransferTab {
        TransferTab(rawValue: tabControl.selectedSegmentIndex) ?? .downloading
    }

    private var activeTransfers: [Transfer] {
        transfers.filter { $0.state.isActive }
    }

    private var activeDownloads: [Transfer] {
        activeTransfers.filter { !$0.isUpload }
    }

    private var activeUploads: [Transfer] {
        activeTransfers.filter { $0.isUpload }
    }

    private var selectedCount: Int {
        selectedTransfers.count + selectedFiles.count
    }

    private var selectionActionTitle: String {
        currentTab == .uploading ? "Cancel" : "Delete"
    }

    /// Files the current tab can select. Empty unless the Downloaded tab is showing.
    private var selectableFileURLs: Set<URL> {
        guard currentTab == .downloaded else { return [] }
        return Set(visibleDownloadedFiles(activeDownloads: activeDownloads).map(\.url))
    }

    /// Transfers the current tab can select. Empty while the Downloaded tab is showing.
    private var selectableTransferIDs: Set<UInt32> {
        guard currentTab != .downloaded else { return [] }
        let candidates = currentTab == .uploading ? activeUploads : activeDownloads
        return Set(candidates.map(\.id))
    }

    private lazy var sortItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down"),
                                   style: .plain, target: nil, action: nil)
        item.accessibilityLabel = "Sort downloaded files"
        return item
    }()

    private lazy var layoutItem = UIBarButtonItem(image: UIImage(systemName: "list.bullet.indent"),
                                                  style: .plain, target: self,
                                                  action: #selector(toggleLayout))

    private lazy var selectItem = UIBarButtonItem(title: "Select", style: .plain,
                                                  target: self, action: #selector(beginSelecting))

    private lazy var doneItem = UIBarButtonItem(title: "Done", style: .plain,
                                                target: self, action: #selector(finishSelecting))

    private lazy var selectionActionItem: UIBarButtonItem = {
        let item = UIBarButtonItem(title: "Delete", style: .plain,
                                   target: self, action: #selector(performSelectionAction))
        item.tintColor = .systemRed
        return item
    }()

    private lazy var selectAllItem = UIBarButtonItem(title: "Select All", style: .plain,
                                                     target: self, action: #selector(toggleSelectAll))

    private lazy var shareGesture = UILongPressGestureRecognizer(target: self,
                                                                 action: #selector(handleLongPress(_:)))

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
        title = "Transfers"
        view.backgroundColor = .systemBackground
        sortOrder = client.store.downloadSortOrder
        layout = client.store.downloadLayout
        toolbarItems = [.flexibleSpace(), selectAllItem, .flexibleSpace()]

        configureLayout()
        updateSortItem()
        updateLayoutItem()
        updateNavigation()

        client.transferChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transfer in self?.merge(transfer) }
            .store(in: &cancellables)

        reloadActiveTransfers()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateNavigation()
        navigationController?.setToolbarHidden(!isSelecting, animated: animated)
        // Selection uses a frozen snapshot, so live changes are picked up when it ends.
        guard !isSelecting else { return }
        reloadActiveTransfers()
        reloadDownloadedFiles()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    private func configureLayout() {
        tabControl.selectedSegmentIndex = client.store.transferTab.rawValue
        tabControl.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
        tabControl.translatesAutoresizingMaskIntoConstraints = false

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 84
        tableView.register(TransferCell.self, forCellReuseIdentifier: TransferCell.reuseIdentifier)
        tableView.addGestureRecognizer(shareGesture)

        messageView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(tabControl)
        view.addSubview(tableView)
        view.addSubview(messageView)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            tabControl.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            tabControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            tabControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            tableView.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            messageView.topAnchor.constraint(equalTo: guide.topAnchor, constant: Theme.emptyStateTopInset),
            messageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            messageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            messageView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func updateNavigation() {
        if isSelecting {
            navigationItem.leftBarButtonItems = [doneItem]
            navigationItem.rightBarButtonItems = [selectionActionItem]
            updateSelectionControls()
        } else {
            navigationItem.leftBarButtonItems = currentTab == .downloaded ? [sortItem, layoutItem] : nil
            navigationItem.rightBarButtonItems = [selectItem]
            selectItem.isEnabled = !displayed.isEmpty
        }
    }

    private func updateLayoutItem() {
        let willShowTree = layout == .list
        layoutItem.image = UIImage(systemName: willShowTree ? "list.bullet.indent" : "list.bullet")
        layoutItem.accessibilityLabel = willShowTree ? "View as tree" : "View as list"
    }

    @objc private func toggleLayout() {
        layout = layout == .list ? .tree : .list
        client.store.downloadLayout = layout
        updateLayoutItem()
        rebuild()
    }

    private func updateSortItem() {
        sortItem.menu = UIMenu(children: DownloadSortOrder.allCases.map { order in
            UIAction(title: order.displayName, state: sortOrder == order ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.sortOrder = order
                self.client.store.downloadSortOrder = order
                self.updateSortItem()
                self.rebuild()
            }
        })
    }

    // MARK: Updates

    private func merge(_ transfer: Transfer) {
        // Selection operates on a stable snapshot; rows must not move or disappear mid-selection.
        guard !isSelecting else { return }

        let targetTab: TransferTab = transfer.isUpload ? .uploading : .downloading
        let isVisible = targetTab == currentTab
        let existed = transfers.contains { $0.id == transfer.id }

        if transfer.state.isActive {
            if let index = transfers.firstIndex(where: { $0.id == transfer.id }) {
                transfers[index] = transfer
                if isVisible { updateVisibleTransfer(transfer) }
            } else {
                transfers.append(transfer)
                if isVisible { rebuild() } else { refreshTabTitles() }
            }
        } else {
            transfers.removeAll { $0.id == transfer.id }
            if existed {
                if isVisible { rebuild() } else { refreshTabTitles() }
            }
            if !transfer.isUpload { scheduleDownloadedFilesReload() }
        }
    }

    private func updateVisibleTransfer(_ transfer: Transfer) {
        guard let row = displayed.firstIndex(where: { item in
            guard case .transfer(let current) = item else { return false }
            return current.id == transfer.id
        }) else {
            rebuild()
            return
        }

        displayed[row] = .transfer(transfer)
        let indexPath = IndexPath(row: row, section: 0)
        guard tableView.indexPathsForVisibleRows?.contains(indexPath) == true,
              let cell = tableView.cellForRow(at: indexPath) as? TransferCell else { return }
        cell.configure(with: transfer)
    }

    private func reloadActiveTransfers() {
        transfers = client.transfers().filter { $0.state.isActive }
        rebuild()
    }

    private func scheduleDownloadedFilesReload() {
        guard !scanScheduled else { return }
        scanScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.scanScheduled = false
            self?.reloadDownloadedFiles()
        }
    }

    private func reloadDownloadedFiles() {
        scanGeneration += 1
        let generation = scanGeneration
        let root = client.store.downloadsDirectory

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let files = DownloadedFiles.scan(in: root)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanGeneration == generation, !self.isSelecting else { return }
                self.downloadedFiles = files
                if self.currentTab == .downloaded {
                    self.rebuild()
                } else {
                    self.refreshTabTitles()
                }
            }
        }
    }

    private func rebuild() {
        let active = activeTransfers
        let downloads = active.filter { !$0.isUpload }
        let uploads = active.filter { $0.isUpload }
        let downloaded = visibleDownloadedFiles(activeDownloads: downloads)

        switch currentTab {
        case .downloading:
            displayed = downloads.map(Item.transfer)
        case .downloaded:
            displayed = downloadedItems(from: downloaded)
        case .uploading:
            displayed = uploads.map(Item.transfer)
        }

        setTabTitles(downloading: downloads.count, downloaded: downloaded.count,
                     uploading: uploads.count)
        tableView.reloadData()
        updateEmptyState()
        updateNavigation()
    }

    private func downloadedItems(from files: [DownloadedFile]) -> [Item] {
        switch layout {
        case .list:
            return sortOrder.sorted(files).map { .file($0, depth: 0) }
        case .tree:
            return treeItems(in: DownloadTree.build(from: files, sortOrder: sortOrder), depth: 0)
        }
    }

    private func treeItems(in folder: DownloadFolder, depth: Int) -> [Item] {
        let folders = folder.folders.flatMap { child -> [Item] in
            var items: [Item] = [.folder(child, depth: depth)]
            if expandedFolders.contains(child.path) {
                items += treeItems(in: child, depth: depth + 1)
            }
            return items
        }
        return folders + folder.files.map { .file($0, depth: depth) }
    }

    private func toggle(_ folder: DownloadFolder, at row: Int, depth: Int) {
        let children = treeItems(in: folder, depth: depth + 1)
        let rows = (row + 1..<row + 1 + children.count).map { IndexPath(row: $0, section: 0) }
        let wasExpanded = expandedFolders.contains(folder.path)

        if wasExpanded {
            expandedFolders.remove(folder.path)
            displayed.removeSubrange(row + 1..<row + 1 + children.count)
        } else {
            expandedFolders.insert(folder.path)
            displayed.insert(contentsOf: children, at: row + 1)
        }

        if let cell = tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? TransferCell {
            cell.configure(with: folder, depth: depth, isExpanded: !wasExpanded)
        }

        tableView.performBatchUpdates {
            if wasExpanded {
                tableView.deleteRows(at: rows, with: .top)
            } else {
                tableView.insertRows(at: rows, with: .top)
            }
        }
    }

    private func refreshTabTitles() {
        let active = activeTransfers
        let downloads = active.filter { !$0.isUpload }
        let uploads = active.filter { $0.isUpload }
        setTabTitles(downloading: downloads.count,
                     downloaded: visibleDownloadedFiles(activeDownloads: downloads).count,
                     uploading: uploads.count)
    }

    private func setTabTitles(downloading: Int, downloaded: Int, uploading: Int) {
        tabControl.setTitle(downloading > 0 ? "Downloading (\(downloading))" : "Downloading",
                            forSegmentAt: TransferTab.downloading.rawValue)
        tabControl.setTitle(downloaded > 0 ? "Downloaded (\(downloaded))" : "Downloaded",
                            forSegmentAt: TransferTab.downloaded.rawValue)
        tabControl.setTitle(uploading > 0 ? "Uploading (\(uploading))" : "Uploading",
                            forSegmentAt: TransferTab.uploading.rawValue)
    }

    /// Files still being downloaded are not downloaded yet, even though a partial file exists on disk.
    private func visibleDownloadedFiles(activeDownloads: [Transfer]) -> [DownloadedFile] {
        let activePaths = Set(activeDownloads.compactMap { transfer in
            PathSanitizer.destination(in: client.store.downloadsDirectory,
                                      username: transfer.username,
                                      virtualPath: transfer.filename)?.standardizedFileURL.path
        })
        return downloadedFiles.filter { !activePaths.contains($0.url.standardizedFileURL.path) }
    }

    private func updateEmptyState() {
        guard displayed.isEmpty else {
            messageView.isHidden = true
            return
        }
        messageView.isHidden = false

        switch currentTab {
        case .downloading:
            messageView.configure(title: "No active downloads",
                                  message: "Files you download appear here.",
                                  symbol: "arrow.down.circle")
        case .downloaded:
            messageView.configure(title: "No downloaded files",
                                  message: "Files in your Downloads folder appear here.",
                                  symbol: "checkmark.circle")
        case .uploading:
            messageView.configure(title: "No active uploads",
                                  message: "Files other users take from your share appear here.",
                                  symbol: "arrow.up.circle")
        }
    }

    @objc private func tabChanged() {
        client.store.transferTab = currentTab
        updateNavigation()
        if currentTab == .downloaded {
            rebuild()
            reloadDownloadedFiles()
        } else {
            reloadActiveTransfers()
        }
    }

    // MARK: Selection

    @objc private func beginSelecting() {
        guard !displayed.isEmpty else { return }
        isSelecting = true
        selectedTransfers.removeAll()
        selectedFiles.removeAll()
        tabControl.isEnabled = false
        shareGesture.isEnabled = false
        tableView.reloadData()
        updateNavigation()
        navigationController?.setToolbarHidden(false, animated: true)
    }

    @objc private func finishSelecting() {
        guard !isDeleting else { return }
        endSelection()
    }

    /// Leaves selection mode and resyncs with changes that arrived while it was frozen.
    private func endSelection() {
        isSelecting = false
        isDeleting = false
        selectedTransfers.removeAll()
        selectedFiles.removeAll()
        tabControl.isEnabled = true
        shareGesture.isEnabled = true
        tableView.isUserInteractionEnabled = true
        doneItem.isEnabled = true
        transfers = client.transfers().filter { $0.state.isActive }
        rebuild()
        updateSelectionControls()
        navigationController?.setToolbarHidden(true, animated: true)
        reloadDownloadedFiles()
    }

    @objc private func toggleSelectAll() {
        if currentTab == .downloaded {
            toggle(&selectedFiles, in: selectableFileURLs)
        } else {
            toggle(&selectedTransfers, in: selectableTransferIDs)
        }
        tableView.reloadData()
        updateSelectionControls()
    }

    /// Selects every item in `items`, or clears them all when they are already selected.
    private func toggle<T: Hashable>(_ selection: inout Set<T>, in items: Set<T>) {
        if items.isSubset(of: selection) {
            selection.subtract(items)
        } else {
            selection.formUnion(items)
        }
    }

    private func toggleSelection(at indexPath: IndexPath) {
        switch displayed[indexPath.row] {
        case .transfer(let transfer):
            if selectedTransfers.contains(transfer.id) {
                selectedTransfers.remove(transfer.id)
            } else {
                selectedTransfers.insert(transfer.id)
            }

        case .file(let file, _):
            if selectedFiles.contains(file.url) {
                selectedFiles.remove(file.url)
            } else {
                selectedFiles.insert(file.url)
            }

        case .folder(let folder, _):
            toggle(&selectedFiles, in: Set(folder.allFiles.map(\.url)))
        }

        tableView.reloadData()
        updateSelectionControls()
    }

    private func updateSelectionControls() {
        let count = selectedCount
        selectionActionItem.title = count > 0 ? "\(selectionActionTitle) (\(count))" : selectionActionTitle
        selectionActionItem.isEnabled = count > 0 && tableView.isUserInteractionEnabled
        selectionActionItem.tintColor = currentTab == .uploading ? .systemBlue : .systemRed

        let selectableFiles = selectableFileURLs
        let selectableTransfers = selectableTransferIDs
        let hasSelectableItems = !selectableFiles.isEmpty || !selectableTransfers.isEmpty
        let allSelected = currentTab == .downloaded
            ? !selectableFiles.isEmpty && selectableFiles.isSubset(of: selectedFiles)
            : !selectableTransfers.isEmpty && selectableTransfers.isSubset(of: selectedTransfers)

        selectAllItem.title = allSelected ? "Deselect All" : "Select All"
        selectAllItem.isEnabled = hasSelectableItems && tableView.isUserInteractionEnabled
    }

    @objc private func performSelectionAction() {
        guard selectedCount > 0, !isDeleting else { return }

        let count = selectedCount
        let isUploading = currentTab == .uploading
        let noun = isUploading
            ? (count == 1 ? "upload" : "uploads")
            : (count == 1 ? "item" : "items")

        let alert = UIAlertController(
            title: "\(isUploading ? "Cancel" : "Delete") \(count) \(noun)?",
            message: "This action cannot be undone",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(
            title: isUploading ? "Cancel Uploads" : "Delete",
            style: isUploading ? .default : .destructive
        ) { [weak self] _ in
            self?.commitSelectionAction()
        })
        present(alert, animated: true)
    }

    /// Deletes selected downloaded files, cancelling selected transfers first. Uploads are only
    /// cancelled, since they have no local copy.
    private func commitSelectionAction() {
        guard selectedCount > 0, !isDeleting else { return }
        isDeleting = true

        let root = client.store.downloadsDirectory
        let selected = transfers.filter { selectedTransfers.contains($0.id) }
        var urls = selectedFiles
        if currentTab == .downloading {
            // A selected download may have finished while the user was selecting; remove its
            // completed file as well as cancelling the transfer.
            for transfer in selected where !transfer.isUpload {
                guard let url = PathSanitizer.destination(in: root, username: transfer.username,
                                                          virtualPath: transfer.filename) else { continue }
                urls.insert(url.standardizedFileURL)
            }
        }

        let count = selectedCount
        let isUploading = currentTab == .uploading
        let ids = selected.map(\.id)
        let files = Array(urls)

        tableView.isUserInteractionEnabled = false
        doneItem.isEnabled = false
        selectionActionItem.isEnabled = false
        selectAllItem.isEnabled = false

        client.cancelTransfers(ids: ids) { [weak self] in
            guard let self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                files.forEach { DownloadedFiles.delete($0, upTo: root) }
                DispatchQueue.main.async {
                    let deleted = Set(files)
                    self.downloadedFiles.removeAll { deleted.contains($0.url.standardizedFileURL) }
                    self.endSelection()
                    if isUploading {
                        let noun = count == 1 ? "upload" : "uploads"
                        Theme.showToast("Cancelled \(count) \(noun)", in: self.view)
                    } else {
                        let noun = count == 1 ? "download" : "downloads"
                        Theme.showToast("Deleted \(count) \(noun)", in: self.view)
                    }
                }
            }
        }
    }

    private func selectionState(for item: Item) -> TransferCell.SelectionState {
        guard isSelecting else { return .hidden }
        switch item {
        case .transfer(let transfer):
            return selectedTransfers.contains(transfer.id) ? .on : .off
        case .file(let file, _):
            return selectedFiles.contains(file.url) ? .on : .off
        case .folder(let folder, _):
            let urls = folder.allFiles.map(\.url)
            let count = urls.reduce(0) { $0 + (selectedFiles.contains($1) ? 1 : 0) }
            if count == 0 { return .off }
            return count == urls.count ? .on : .partial
        }
    }

    // MARK: Downloaded files

    private func presentPreview(for file: DownloadedFile) {
        guard FileManager.default.fileExists(atPath: file.url.path) else {
            Theme.showToast("This file is no longer on the device", in: view)
            return
        }
        previewURL = file.url
        let controller = QLPreviewController()
        controller.dataSource = self
        present(controller, animated: true)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, !isSelecting else { return }
        let point = gesture.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: point),
              displayed.indices.contains(indexPath.row),
              case .file(let file, _) = displayed[indexPath.row],
              FileManager.default.fileExists(atPath: file.url.path) else { return }

        let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        Theme.configurePopover(controller, in: tableView, rect: tableView.rectForRow(at: indexPath))
        present(controller, animated: true)
    }
}

// MARK: - UITableViewDataSource

extension TransfersViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        displayed.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: TransferCell.reuseIdentifier, for: indexPath)
        let item = displayed[indexPath.row]
        switch item {
        case .transfer(let transfer):
            (cell as? TransferCell)?.configure(with: transfer)
        case .file(let file, let depth):
            (cell as? TransferCell)?.configure(with: file, depth: depth, showsFolder: layout == .list)
        case .folder(let folder, let depth):
            (cell as? TransferCell)?.configure(with: folder, depth: depth,
                                               isExpanded: expandedFolders.contains(folder.path))
        }
        (cell as? TransferCell)?.configureSelection(selectionState(for: item))
        return cell
    }
}

// MARK: - UITableViewDelegate

extension TransfersViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if isSelecting {
            toggleSelection(at: indexPath)
            return
        }
        switch displayed[indexPath.row] {
        case .file(let file, _):
            presentPreview(for: file)
        case .folder(let folder, let depth):
            toggle(folder, at: indexPath.row, depth: depth)
        case .transfer:
            break
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        guard !isSelecting else { return nil }
        switch displayed[indexPath.row] {
        case .folder(let folder, _):
            let action = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
                guard let self else { completion(false); return }
                self.delete(folder.allFiles, toast: "Deleted \(folder.name)")
                completion(true)
            }
            return UISwipeActionsConfiguration(actions: [action])

        case .transfer(let transfer):
            let action = UIContextualAction(style: .destructive, title: "Cancel") { [weak self] _, _, completion in
                self?.client.cancelTransfers(ids: [transfer.id])
                completion(true)
            }
            return UISwipeActionsConfiguration(actions: [action])

        case .file(let file, _):
            let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
                guard let self else { completion(false); return }
                self.delete([file], toast: "Deleted \(file.name)")
                completion(true)
            }

            let filesAction = UIContextualAction(style: .normal, title: "Files") { [weak self] _, _, completion in
                guard let self else { completion(false); return }
                self.showInFiles(file, completion: completion)
            }
            filesAction.image = UIImage(systemName: "folder")
            filesAction.backgroundColor = .systemBlue
            filesAction.accessibilityLabel = "Show in Files"

            return UISwipeActionsConfiguration(actions: [deleteAction, filesAction])
        }
    }

    /// Removes files and updates the list without waiting for the next filesystem scan.
    private func delete(_ files: [DownloadedFile], toast: String) {
        let root = client.store.downloadsDirectory
        files.forEach { DownloadedFiles.delete($0.url, upTo: root) }

        scanGeneration += 1
        let deleted = Set(files.map(\.url))
        downloadedFiles.removeAll { deleted.contains($0.url) }
        rebuild()
        Theme.showToast(toast, in: view)
    }

    /// Opens the containing folder in Files. There is no public API for this; `shareddocuments://`
    /// is the de facto scheme, and folders open more reliably than files.
    private func showInFiles(_ file: DownloadedFile, completion: @escaping (Bool) -> Void) {
        guard FileManager.default.fileExists(atPath: file.url.path) else {
            Theme.showToast("This file is no longer on the device", in: view)
            completion(false)
            return
        }

        let folder = file.url.deletingLastPathComponent()
        let path = folder.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? folder.path
        guard let url = URL(string: "shareddocuments://\(path)") else {
            completion(false)
            return
        }

        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            if !opened, let self {
                let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? "iSoulseek"
                Theme.showToast("Open Files › On My iPhone › \(appName) › Downloads", in: self.view)
            }
            completion(true)
        }
    }
}

// MARK: - QLPreviewControllerDataSource

extension TransfersViewController: QLPreviewControllerDataSource {

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        (previewURL ?? client.store.downloadsDirectory) as NSURL
    }
}

// MARK: - TransferCell

private final class TransferCell: UITableViewCell {

    static let reuseIdentifier = "TransferCell"

    enum SelectionState {
        case hidden
        case off
        case partial
        case on
    }

    private static let iconConfiguration = UIImage.SymbolConfiguration(textStyle: .title3)
    private static let selectionConfiguration = UIImage.SymbolConfiguration(pointSize: 21, weight: .regular)

    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private var leadingConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(with transfer: Transfer) {
        iconView.image = UIImage(systemName: transfer.isUpload ? "arrow.up" : "arrow.down",
                                 withConfiguration: Self.iconConfiguration)
        iconView.tintColor = transfer.isUpload ? .systemOrange : .systemBlue
        nameLabel.text = transfer.localFilename
        statusLabel.text = "\(transfer.username) · \(transfer.stateDescription)"
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.isHidden = false
        detailLabel.isHidden = false
        accessoryType = .none
        setDepth(0)

        progressView.isHidden = !transfer.state.isActive
        progressView.progress = transfer.progress

        if transfer.state.isActive {
            var detail = "\(Formatters.bytes(transfer.transferred)) of \(Formatters.bytes(transfer.size))"
            detail += " · \(Int(transfer.progress * 100))%"
            if transfer.averageSpeed > 0 { detail += " · \(Formatters.speed(transfer.averageSpeed))" }
            detailLabel.text = detail
        } else {
            detailLabel.text = Formatters.bytes(transfer.size)
        }
    }

    func configure(with file: DownloadedFile, depth: Int, showsFolder: Bool) {
        let symbol = Theme.mediaSymbol(forExtension: file.url.pathExtension) ?? "doc"
        iconView.image = UIImage(systemName: symbol, withConfiguration: Self.iconConfiguration)
        iconView.tintColor = .secondaryLabel
        nameLabel.text = file.name
        statusLabel.text = file.folder
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.isHidden = !showsFolder
        detailLabel.isHidden = false
        accessoryType = .disclosureIndicator
        setDepth(depth)
        progressView.isHidden = true
        detailLabel.text = "\(Formatters.bytes(file.size)) · \(file.modified.formatted(date: .abbreviated, time: .shortened))"
    }

    func configure(with folder: DownloadFolder, depth: Int, isExpanded: Bool) {
        iconView.image = UIImage(systemName: isExpanded ? "folder.fill" : "folder",
                                 withConfiguration: Self.iconConfiguration)
        iconView.tintColor = .systemBlue
        nameLabel.text = folder.name
        let count = folder.fileCount
        let files = "\(count.formatted()) \(count == 1 ? "file" : "files")"
        statusLabel.text = "\(files) · \(Formatters.bytes(folder.totalSize))"
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.isHidden = false
        detailLabel.isHidden = true
        accessoryType = .disclosureIndicator
        setDepth(depth)
        progressView.isHidden = true
    }

    func configureSelection(_ state: SelectionState) {
        guard state != .hidden else {
            accessoryView = nil
            accessibilityTraits.remove(.selected)
            accessibilityValue = nil
            return
        }

        let symbol: String
        let tint: UIColor
        switch state {
        case .off:
            symbol = "circle"
            tint = .tertiaryLabel
        case .partial:
            symbol = "minus.circle.fill"
            tint = .systemBlue
        case .on:
            symbol = "checkmark.circle.fill"
            tint = .systemBlue
        case .hidden:
            return
        }

        let image = UIImage(systemName: symbol, withConfiguration: Self.selectionConfiguration)
        let imageView = UIImageView(image: image)
        imageView.tintColor = tint
        imageView.contentMode = .scaleAspectFit
        accessoryView = imageView
        accessoryType = .none

        if state == .on {
            accessibilityTraits.insert(.selected)
            accessibilityValue = "Selected"
        } else {
            accessibilityTraits.remove(.selected)
            accessibilityValue = state == .partial ? "Partially selected" : "Not selected"
        }
    }

    private func setDepth(_ depth: Int) {
        leadingConstraint.constant = 16 + CGFloat(depth) * 16
    }

    private func setup() {
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        nameLabel.font = .preferredFont(forTextStyle: .subheadline)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingMiddle

        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 1

        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .tertiaryLabel
        detailLabel.numberOfLines = 1

        let labels = UIStackView(arrangedSubviews: [nameLabel, statusLabel, progressView, detailLabel])
        labels.axis = .vertical
        labels.spacing = 4

        let row = UIStackView(arrangedSubviews: [iconView, labels])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        leadingConstraint = row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            leadingConstraint,
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }
}
