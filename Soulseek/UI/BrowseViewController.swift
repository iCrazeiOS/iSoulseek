import UIKit

/// A user's share, one section per folder. Folders expand one at a time.
final class BrowseViewController: UIViewController {

    private let username: String
    private let client: SoulseekClient

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let messageView = MessageView()

    private var folders: [ShareFolder] = []
    private var expandedPath: String?
    private var hasLoaded = false

    init(username: String, client: SoulseekClient) {
        self.username = username
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = username
        view.backgroundColor = .systemBackground
        configureTable()
        load()
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
        tableView.estimatedRowHeight = 64
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.estimatedSectionHeaderHeight = 60
        tableView.register(BrowseFileCell.self, forCellReuseIdentifier: BrowseFileCell.reuseIdentifier)
        tableView.register(FolderHeaderView.self,
                           forHeaderFooterViewReuseIdentifier: FolderHeaderView.reuseIdentifier)
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

    // MARK: Loading

    private func load() {
        messageView.isHidden = false
        messageView.configure(title: "Loading \(username)…",
                              message: "Fetching the shared file list.",
                              loading: true)
        client.browse(username: username) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let folders):
                self.folders = folders
                self.hasLoaded = true
                self.messageView.isHidden = true
                self.updateSummary()
                self.tableView.reloadData()

            case .failure(let error):
                self.messageView.configure(title: "Could not browse \(self.username)",
                                           message: error.localizedDescription,
                                           actionTitle: "Retry") { [weak self] in self?.load() }
            }
        }
    }

    private func updateSummary() {
        let fileCount = folders.reduce(0) { $0 + $1.files.count }
        let totalSize = folders.reduce(UInt64(0)) { $0 + $1.files.reduce(UInt64(0)) { $0 + $1.size } }
        navigationItem.prompt = "\(fileCount.formatted()) files · \(Formatters.bytes(totalSize))"
    }

    // MARK: Actions

    private func toggle(_ folder: ShareFolder) {
        expandedPath = expandedPath == folder.path ? nil : folder.path
        tableView.reloadData()
    }

    private func download(file: ShareFile, in folder: ShareFolder) {
        let path = folder.path + "\\" + file.name
        client.download(username: username, filename: path, size: file.size) { [weak self] transfer in
            guard let self else { return }
            Theme.showToast(transfer == nil ? "Could not download \(file.name)"
                                            : "Added \(file.name) to downloads", in: self.view)
        }
    }

    private func download(folder: ShareFolder) {
        guard !folder.files.isEmpty else { return }
        for file in folder.files {
            client.download(username: username, filename: folder.path + "\\" + file.name, size: file.size)
        }
        Theme.showToast("Queued \(folder.files.count) files", in: view)
    }
}

// MARK: - UITableViewDataSource

extension BrowseViewController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        folders.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        folders[section].path == expandedPath ? folders[section].files.count : 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: BrowseFileCell.reuseIdentifier,
                                                 for: indexPath)
        let file = folders[indexPath.section].files[indexPath.row]
        (cell as? BrowseFileCell)?.configure(with: file)
        return cell
    }
}

// MARK: - UITableViewDelegate

extension BrowseViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let folder = folders[section]
        let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: FolderHeaderView.reuseIdentifier) as? FolderHeaderView
        header?.configure(folder: folder, isExpanded: folder.path == expandedPath)
        header?.onToggle = { [weak self] in self?.toggle(folder) }
        header?.onDownload = { [weak self] in self?.download(folder: folder) }
        return header
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let folder = folders[indexPath.section]
        download(file: folder.files[indexPath.row], in: folder)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        let folder = folders[indexPath.section]
        let file = folder.files[indexPath.row]
        let action = UIContextualAction(style: .normal, title: "Download") { [weak self] _, _, completion in
            self?.download(file: file, in: folder)
            completion(true)
        }
        action.backgroundColor = .systemBlue
        return UISwipeActionsConfiguration(actions: [action])
    }
}

// MARK: - FolderHeaderView

private final class FolderHeaderView: UITableViewHeaderFooterView {

    static let reuseIdentifier = "FolderHeaderView"

    var onToggle: (() -> Void)?
    var onDownload: (() -> Void)?

    private let chevron = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let downloadButton = UIButton(type: .system)

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(folder: ShareFolder, isExpanded: Bool) {
        let components = ShareFolder.components(of: folder.path)
        titleLabel.text = components.last ?? folder.path
        let size = folder.files.reduce(UInt64(0)) { $0 + $1.size }
        subtitleLabel.text = "\(folder.files.count) files · \(Formatters.bytes(size))"
        chevron.image = UIImage(systemName: isExpanded ? "chevron.down" : "chevron.right")
        downloadButton.isEnabled = !folder.files.isEmpty
    }

    private func setup() {
        contentView.backgroundColor = .secondarySystemBackground

        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 1

        downloadButton.setTitle("Download", for: .normal)
        downloadButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        downloadButton.setContentHuggingPriority(.required, for: .horizontal)
        downloadButton.addTarget(self, action: #selector(downloadTapped), for: .touchUpInside)

        let labels = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        labels.axis = .vertical
        labels.spacing = 1

        let row = UIStackView(arrangedSubviews: [chevron, labels, downloadButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        NSLayoutConstraint.activate([
            chevron.widthAnchor.constraint(equalToConstant: 12),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleTapped))
        contentView.addGestureRecognizer(tap)
    }

    @objc private func toggleTapped() {
        onToggle?()
    }

    @objc private func downloadTapped() {
        onDownload?()
    }
}

// MARK: - BrowseFileCell

private final class BrowseFileCell: UITableViewCell {

    static let reuseIdentifier = "BrowseFileCell"

    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(with file: ShareFile) {
        titleLabel.text = file.name
        icon.image = Theme.mediaSymbol(forExtension: file.fileExtension).flatMap(UIImage.init(systemName:))
        icon.isHidden = icon.image == nil
        metaLabel.text = metaText(for: file)
    }

    private func metaText(for file: ShareFile) -> String {
        var parts = [Formatters.bytes(file.size)]
        if let bitrate = file.bitrate, bitrate > 0 { parts.append("\(bitrate) kbps") }
        if let duration = file.duration, duration > 0 { parts.append(Formatters.duration(duration)) }
        return parts.joined(separator: "  ·  ")
    }

    private func setup() {
        icon.tintColor = .tertiaryLabel
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingMiddle

        metaLabel.font = .preferredFont(forTextStyle: .caption1)
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.textColor = .secondaryLabel
        metaLabel.numberOfLines = 1

        let labels = UIStackView(arrangedSubviews: [titleLabel, metaLabel])
        labels.axis = .vertical
        labels.spacing = 1

        let row = UIStackView(arrangedSubviews: [icon, labels])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }
}
