import Combine
import QuickLook
import UIKit

/// Transfers, split into a "Downloading" tab (active) and a "Completed" tab (finished).
final class DownloadsViewController: UIViewController {

    private let client: SoulseekClient
    private var cancellables = Set<AnyCancellable>()

    private let tabControl = UISegmentedControl(items: ["Downloading", "Completed"])
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let messageView = MessageView()

    private var transfers: [Transfer] = []
    private var displayed: [Transfer] = []
    private var reloadScheduled = false
    private var previewURL: URL?

    private var showsCompleted: Bool {
        get { tabControl.selectedSegmentIndex == 1 }
        set { tabControl.selectedSegmentIndex = newValue ? 1 : 0 }
    }

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
        navigationItem.rightBarButtonItem = deleteItem

        configureLayout()
        transfers = client.transfers()
        rebuild()

        client.transferChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transfer in self?.merge(transfer) }
            .store(in: &cancellables)
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

            messageView.topAnchor.constraint(equalTo: tableView.topAnchor),
            messageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            messageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            messageView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    // MARK: Updates

    private func merge(_ transfer: Transfer) {
        if let index = transfers.firstIndex(where: { $0.id == transfer.id }) {
            transfers[index] = transfer
        } else {
            transfers.append(transfer)
        }
        scheduleReload()
    }

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.reloadScheduled = false
            self?.rebuild()
        }
    }

    private func rebuild() {
        let active = transfers.filter { $0.state.isActive }
        let finished = Array(transfers.filter { !$0.state.isActive }.reversed())
        displayed = showsCompleted ? finished : active

        let activeCount = active.count
        tabControl.setTitle(activeCount > 0 ? "Downloading (\(activeCount))" : "Downloading", forSegmentAt: 0)
        tabControl.setTitle(finished.isEmpty ? "Completed" : "Completed (\(finished.count))", forSegmentAt: 1)

        tableView.reloadData()
        updateEmptyState()
    }

    private func updateEmptyState() {
        guard displayed.isEmpty else {
            messageView.isHidden = true
            return
        }
        messageView.isHidden = false
        if showsCompleted {
            messageView.configure(title: "No completed transfers",
                                 message: "Finished downloads and uploads appear here.")
        } else {
            messageView.configure(title: "No active transfers",
                                 message: "Files you download appear here, along with anything other users take from your share.")
        }
    }

    @objc private func tabChanged() {
        rebuild()
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
        client.deleteAllDownloads()
        transfers = client.transfers()
        rebuild()
    }

    // MARK: Completed downloads

    /// Where a download's bytes live on disk, mirroring the transfer manager's sanitisation.
    private func localURL(for transfer: Transfer) -> URL? {
        PathSanitizer.destination(in: client.store.downloadsDirectory, virtualPath: transfer.filename)
    }

    private func canPreview(_ transfer: Transfer) -> Bool {
        showsCompleted && !transfer.isUpload && transfer.state == .completed
    }

    private func presentPreview(for transfer: Transfer) {
        guard let url = localURL(for: transfer), FileManager.default.fileExists(atPath: url.path) else {
            Theme.showToast("This file is no longer on the device", in: view)
            return
        }
        previewURL = url
        let controller = QLPreviewController()
        controller.dataSource = self
        present(controller, animated: true)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: point), indexPath.row < displayed.count else { return }
        let transfer = displayed[indexPath.row]
        guard canPreview(transfer), let url = localURL(for: transfer),
              FileManager.default.fileExists(atPath: url.path) else { return }

        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
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
        let cell = tableView.dequeueReusableCell(withIdentifier: TransferCell.reuseIdentifier, for: indexPath)
        let transfer = displayed[indexPath.row]
        (cell as? TransferCell)?.configure(with: transfer, showsChevron: canPreview(transfer))
        return cell
    }
}

// MARK: - UITableViewDelegate

extension DownloadsViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let transfer = displayed[indexPath.row]
        guard canPreview(transfer) else { return }
        presentPreview(for: transfer)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        let transfer = displayed[indexPath.row]

        if transfer.state.isActive {
            let action = UIContextualAction(style: .destructive, title: "Cancel") { [weak self] _, _, completion in
                self?.client.cancelTransfer(id: transfer.id)
                completion(true)
            }
            return UISwipeActionsConfiguration(actions: [action])
        }

        // Deleting a finished download removes the file from disk; other finished rows just go away.
        let deletesFile = !transfer.isUpload && transfer.state == .completed
        let title = deletesFile ? "Delete" : "Remove"
        let action = UIContextualAction(style: .destructive, title: title) { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            self.client.deleteTransfer(id: transfer.id, deleteFile: deletesFile)
            self.transfers = self.client.transfers()
            self.rebuild()
            if deletesFile { Theme.showToast("Deleted \(transfer.localFilename)", in: self.view) }
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
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

// MARK: - TransferCell

private final class TransferCell: UITableViewCell {

    static let reuseIdentifier = "TransferCell"

    private let directionLabel = UILabel()
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
        directionLabel.text = transfer.isUpload ? "↑" : "↓"
        directionLabel.textColor = transfer.isUpload ? .systemOrange : .systemBlue
        nameLabel.text = transfer.localFilename
        statusLabel.text = "\(transfer.username) · \(transfer.state.description)"
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

    private func setup() {
        directionLabel.font = .preferredFont(forTextStyle: .title3)
        directionLabel.adjustsFontForContentSizeCategory = true
        directionLabel.setContentHuggingPriority(.required, for: .horizontal)

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

        let row = UIStackView(arrangedSubviews: [directionLabel, labels])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        NSLayoutConstraint.activate([
            directionLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }
}
