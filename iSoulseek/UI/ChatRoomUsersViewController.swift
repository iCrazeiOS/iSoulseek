import UIKit

/// Snapshot of the people in a room at the moment the user list was opened.
final class ChatRoomUsersViewController: UITableViewController {

    private let users: [ChatRoomUser]

    init(room: String, users: [ChatRoomUser]) {
        self.users = users.sorted {
            $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
        }
        super.init(style: .insetGrouped)
        title = "\(room) Users"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "UserCell")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        users.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "UserCell", for: indexPath)
        let user = users[indexPath.row]

        var content = UIListContentConfiguration.subtitleCell()
        content.text = user.username
        content.secondaryText = user.status.displayName
        content.secondaryTextProperties.color = user.status == .online ? .systemGreen : .secondaryLabel
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }
}
