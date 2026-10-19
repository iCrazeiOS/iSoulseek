import Combine
import UIKit

/// Live list of downloads and uploads, split into active and finished sections.
final class DownloadsViewController: UIViewController {

    private let client: SoulseekClient
    private var cancellables = Set<AnyCancellable>()

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let messageView = MessageView()

    private var transfers: [Transfer] = []
    private var sections: [(title: String, transfers: [Transfer])] = []
    private var reloadScheduled = false

    private lazy var clearItem = UIBarButtonItem(title: "Clear finished", style: .plain,
                                                 target: self, action: #selector(clearFinished))

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
        navigationItem.rightBarButtonItem = clearItem

        configureTable()
        transfers = client.transfers()
        rebuild()

        client.transferChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transfer in self?.merge(transfer) }
            .store(in: &cancellables)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    private func configureTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 84
        tableView.register(TransferCell.self, forCellReuseIdentifier: TransferCell.reuseIdentifier)
        view.addSubview(tableView)

        messageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            messageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
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
        let finished = transfers.filter { !$0.state.isActive }.reversed()

        sections = []
        if !active.isEmpty { sections.append(("Active", active)) }
        if !finished.isEmpty { sections.append(("Finished", Array(finished))) }

        tableView.reloadData()
        clearItem.isEnabled = !finished.isEmpty
        updateEmptyState()
    }

    private func updateEmptyState() {
        guard transfers.isEmpty else {
            messageView.isHidden = true
            return
        }
        messageView.isHidden = false
        messageView.configure(title: "No transfers",
                             message: "Files you download appear here, along with anything other users take from your share.")
    }

    @objc private func clearFinished() {
        client.clearFinishedTransfers()
        transfers = client.transfers()
        rebuild()
    }
}

// MARK: - UITableViewDataSource

extension DownloadsViewController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].transfers.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: TransferCell.reuseIdentifier, for: indexPath)
        (cell as? TransferCell)?.configure(with: sections[indexPath.section].transfers[indexPath.row])
        return cell
    }
}

// MARK: - UITableViewDelegate

extension DownloadsViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        let transfer = sections[indexPath.section].transfers[indexPath.row]
        guard transfer.state.isActive else { return nil }

        let action = UIContextualAction(style: .destructive, title: "Cancel") { [weak self] _, _, completion in
            self?.client.cancelTransfer(id: transfer.id)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
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

    func configure(with transfer: Transfer) {
        directionLabel.text = transfer.isUpload ? "↑" : "↓"
        directionLabel.textColor = transfer.isUpload ? .systemOrange : .systemBlue
        nameLabel.text = transfer.localFilename
        statusLabel.text = "\(transfer.username) · \(transfer.state.description)"

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
