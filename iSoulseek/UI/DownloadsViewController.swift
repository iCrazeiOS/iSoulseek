import Combine
import QuickLook
import UIKit

/// Downloads, split into a "Downloading" tab (active transfers) and a "Completed" tab (files on disk).
final class DownloadsViewController: UIViewController {

    private enum Item {
        case transfer(Transfer)
        case file(DownloadedFile)
    }

    private let client: SoulseekClient
    private var cancellables = Set<AnyCancellable>()

    private let tabControl = UISegmentedControl(items: ["Downloading", "Completed"])
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let messageView = MessageView()

    private var transfers: [Transfer] = []
    private var completedFiles: [DownloadedFile] = []
    private var displayed: [Item] = []
    private var scanScheduled = false
    private var scanGeneration = 0
    private var previewURL: URL?
    private var sortOrder: DownloadSortOrder = .newest

    private var showsCompleted: Bool {
        get { tabControl.selectedSegmentIndex == 1 }
        set { tabControl.selectedSegmentIndex = newValue ? 1 : 0 }
    }

    private lazy var sortItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down"),
                                   style: .plain, target: nil, action: nil)
        item.accessibilityLabel = "Sort completed downloads"
        return item
    }()

    private lazy var deleteItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "trash.fill"), style: .plain,
                                   target: self, action: #selector(confirmDeleteAllDownloads))
        item.accessibilityLabel = "Delete all downloads"
        return item
    }()

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
        title = "Downloads"
        view.backgroundColor = .systemBackground
        sortOrder = client.store.downloadSortOrder
        navigationItem.rightBarButtonItem = deleteItem

        configureLayout()
        updateSortItem()
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
        reloadActiveTransfers()
        reloadCompletedFiles()
    }

    private func configureLayout() {
        tabControl.selectedSegmentIndex = 0
        tabControl.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
        tabControl.translatesAutoresizingMaskIntoConstraints = false

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 84
        tableView.register(DownloadCell.self, forCellReuseIdentifier: DownloadCell.reuseIdentifier)
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
        navigationItem.leftBarButtonItem = showsCompleted ? sortItem : nil
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
        let existed = transfers.contains { $0.id == transfer.id }

        if transfer.state.isActive {
            if let index = transfers.firstIndex(where: { $0.id == transfer.id }) {
                transfers[index] = transfer
                if !showsCompleted { updateVisibleTransfer(transfer) }
                return
            }

            transfers.append(transfer)
            if showsCompleted {
                refreshTabTitles()
            } else {
                rebuild()
            }
        } else {
            transfers.removeAll { $0.id == transfer.id }
            if existed {
                if showsCompleted {
                    refreshTabTitles()
                } else {
                    rebuild()
                }
            }
        }

        if !transfer.isUpload && !transfer.state.isActive {
            scheduleCompletedFilesReload()
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
              let cell = tableView.cellForRow(at: indexPath) as? DownloadCell else { return }
        cell.configure(with: transfer)
    }

    private func reloadActiveTransfers() {
        transfers = client.transfers().filter { $0.state.isActive }
        if showsCompleted {
            refreshTabTitles()
        } else {
            rebuild()
        }
    }

    private func scheduleCompletedFilesReload() {
        guard !scanScheduled else { return }
        scanScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.scanScheduled = false
            self?.reloadCompletedFiles()
        }
    }

    private func reloadCompletedFiles() {
        scanGeneration += 1
        let generation = scanGeneration
        let root = client.store.downloadsDirectory

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let files = DownloadedFiles.scan(in: root)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                self.completedFiles = files
                if self.showsCompleted {
                    self.rebuild()
                } else {
                    self.refreshTabTitles()
                }
            }
        }
    }

    private func rebuild() {
        let active = transfers.filter { $0.state.isActive }
        let completed = visibleCompletedFiles(active: active)
        displayed = showsCompleted
            ? sortOrder.sorted(completed).map(Item.file)
            : active.map(Item.transfer)

        setTabTitles(activeCount: active.count, completedCount: completed.count)
        tableView.reloadData()
        updateEmptyState()
    }

    private func refreshTabTitles() {
        let active = transfers.filter { $0.state.isActive }
        setTabTitles(activeCount: active.count,
                     completedCount: visibleCompletedFiles(active: active).count)
    }

    private func setTabTitles(activeCount: Int, completedCount: Int) {
        tabControl.setTitle(activeCount > 0 ? "Downloading (\(activeCount))" : "Downloading", forSegmentAt: 0)
        tabControl.setTitle(completedCount > 0 ? "Completed (\(completedCount))" : "Completed", forSegmentAt: 1)
    }

    /// Files still being downloaded are not completed, even though a partial file exists on disk.
    private func visibleCompletedFiles(active: [Transfer]) -> [DownloadedFile] {
        let activePaths = Set(active.filter { !$0.isUpload }.compactMap { transfer in
            PathSanitizer.destination(in: client.store.downloadsDirectory,
                                      virtualPath: transfer.filename)?.standardizedFileURL.path
        })
        return completedFiles.filter { !activePaths.contains($0.url.standardizedFileURL.path) }
    }

    private func updateEmptyState() {
        guard displayed.isEmpty else {
            messageView.isHidden = true
            return
        }
        messageView.isHidden = false
        if showsCompleted {
            messageView.configure(title: "No completed downloads",
                                 message: "Files in your Downloads folder appear here.",
                                 symbol: "checkmark.circle")
        } else {
            messageView.configure(title: "No active transfers",
                                 message: "Files you download appear here, along with anything other users take from your share.",
                                 symbol: "arrow.down.circle")
        }
    }

    @objc private func tabChanged() {
        updateNavigation()
        if showsCompleted {
            rebuild()
            reloadCompletedFiles()
        } else {
            reloadActiveTransfers()
        }
    }

    @objc private func confirmDeleteAllDownloads() {
        let alert = UIAlertController(
            title: "Delete all downloads?",
            message: "Every downloaded file, including downloads in progress, will be removed from this device. "
                + "This cannot be undone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.deleteAllDownloads()
        })
        present(alert, animated: true)
    }

    private func deleteAllDownloads() {
        scanGeneration += 1
        completedFiles.removeAll()
        client.deleteAllDownloads { [weak self] in
            self?.reloadCompletedFiles()
        }
        transfers = client.transfers().filter { $0.state.isActive }
        rebuild()
    }

    // MARK: Completed downloads

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
        guard gesture.state == .began else { return }
        let point = gesture.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: point),
              displayed.indices.contains(indexPath.row),
              case .file(let file) = displayed[indexPath.row],
              FileManager.default.fileExists(atPath: file.url.path) else { return }

        let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        Theme.configurePopover(controller, in: tableView, rect: tableView.rectForRow(at: indexPath))
        present(controller, animated: true)
    }
}

// MARK: - UITableViewDataSource

extension DownloadsViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        displayed.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: DownloadCell.reuseIdentifier, for: indexPath)
        switch displayed[indexPath.row] {
        case .transfer(let transfer):
            (cell as? DownloadCell)?.configure(with: transfer)
        case .file(let file):
            (cell as? DownloadCell)?.configure(with: file, showsChevron: true)
        }
        return cell
    }
}

// MARK: - UITableViewDelegate

extension DownloadsViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case .file(let file) = displayed[indexPath.row] else { return }
        presentPreview(for: file)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        switch displayed[indexPath.row] {
        case .transfer(let transfer):
            let action = UIContextualAction(style: .destructive, title: "Cancel") { [weak self] _, _, completion in
                self?.client.cancelTransfer(id: transfer.id)
                completion(true)
            }
            return UISwipeActionsConfiguration(actions: [action])

        case .file(let file):
            let action = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
                guard let self else { completion(false); return }
                DownloadedFiles.delete(file.url, upTo: self.client.store.downloadsDirectory)
                self.scanGeneration += 1
                self.completedFiles.removeAll { $0.url == file.url }
                self.rebuild()
                Theme.showToast("Deleted \(file.name)", in: self.view)
                completion(true)
            }
            return UISwipeActionsConfiguration(actions: [action])
        }
    }
}

// MARK: - QLPreviewControllerDataSource

extension DownloadsViewController: QLPreviewControllerDataSource {

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        (previewURL ?? client.store.downloadsDirectory) as NSURL
    }
}

// MARK: - DownloadCell

private final class DownloadCell: UITableViewCell {

    static let reuseIdentifier = "DownloadCell"

    private static let iconConfiguration = UIImage.SymbolConfiguration(textStyle: .title3)

    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(with transfer: Transfer, showsChevron: Bool = false) {
        iconView.image = UIImage(systemName: transfer.isUpload ? "arrow.up" : "arrow.down",
                                 withConfiguration: Self.iconConfiguration)
        iconView.tintColor = transfer.isUpload ? .systemOrange : .systemBlue
        nameLabel.text = transfer.localFilename
        statusLabel.text = "\(transfer.username) · \(transfer.state.description)"
        statusLabel.lineBreakMode = .byTruncatingTail
        accessoryType = showsChevron ? .disclosureIndicator : .none

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

    func configure(with file: DownloadedFile, showsChevron: Bool = false) {
        let symbol = Theme.mediaSymbol(forExtension: file.url.pathExtension) ?? "doc"
        iconView.image = UIImage(systemName: symbol, withConfiguration: Self.iconConfiguration)
        iconView.tintColor = .secondaryLabel
        nameLabel.text = file.name
        statusLabel.text = file.folder
        statusLabel.lineBreakMode = .byTruncatingMiddle
        accessoryType = showsChevron ? .disclosureIndicator : .none
        progressView.isHidden = true
        detailLabel.text = "\(Formatters.bytes(file.size)) · \(file.modified.formatted(date: .abbreviated, time: .shortened))"
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

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }
}
