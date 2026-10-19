import UIKit

/// Small shared helpers: transient confirmation, media icons and popover plumbing.
enum Theme {

    private static let toastTag = 0x7061_6F73

    /// Shows a short-lived confirmation near the bottom of `view`.
    static func showToast(_ message: String, in view: UIView) {
        view.viewWithTag(toastTag)?.removeFromSuperview()

        let label = BadgeLabel()
        label.tag = toastTag
        label.text = message
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 0
        label.contentInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        label.backgroundColor = .secondarySystemBackground
        label.layer.cornerRadius = 12
        label.layer.cornerCurve = .continuous
        label.layer.borderWidth = 0.5
        label.layer.borderColor = UIColor.separator.cgColor
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])

        label.alpha = 0
        UIView.animate(withDuration: 0.2) { label.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            UIView.animate(withDuration: 0.3, animations: { label.alpha = 0 }) { _ in
                label.removeFromSuperview()
            }
        }
    }

    /// SF Symbol for a file extension, or `nil` when the type is not recognised.
    static func mediaSymbol(forExtension fileExtension: String) -> String? {
        switch fileExtension.lowercased() {
        case "mp3", "flac", "wav", "m4a", "aac", "ogg", "opus", "wma", "aiff", "alac", "m4b":
            return "music.note"
        case "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v", "mpg", "mpeg":
            return "film"
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "webp", "heic":
            return "photo"
        case "pdf", "epub", "mobi", "txt", "rtf", "doc", "docx":
            return "doc.text"
        case "zip", "rar", "7z", "tar", "gz", "bz2":
            return "archivebox"
        default:
            return nil
        }
    }

    /// Anchors a presented controller's popover so it cannot crash on iPad.
    static func configurePopover(_ controller: UIViewController, in view: UIView, rect: CGRect? = nil) {
        guard let popover = controller.popoverPresentationController else { return }
        popover.sourceView = view
        popover.sourceRect = rect ?? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        popover.permittedArrowDirections = rect == nil ? [] : .any
    }
}

/// A text field drawn as a filled, rounded inset.
///
/// The `roundedRect` border style reads as a dated box; this is the modern iOS form
/// field instead: a soft filled background, a capsule shape, roomy padding and a focus
/// ring while the field is being edited.
final class InsetTextField: UITextField {

    /// Space between the edge of the field and its text.
    private static let textPadding: CGFloat = 16

    override init(frame: CGRect) {
        super.init(frame: frame)
        borderStyle = .none
        backgroundColor = .secondarySystemBackground
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        observeEditing()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A capsule stays a capsule when the field grows with the user's text size.
        layer.cornerRadius = bounds.height / 2
    }

    // MARK: Editing state

    private func observeEditing() {
        NotificationCenter.default.addObserver(self, selector: #selector(editingDidBegin),
                                               name: UITextField.textDidBeginEditingNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(editingDidEnd),
                                               name: UITextField.textDidEndEditingNotification, object: self)
    }

    @objc private func editingDidBegin() {
        setFocusRing(true)
    }

    @objc private func editingDidEnd() {
        setFocusRing(false)
    }

    private func setFocusRing(_ visible: Bool) {
        // `UITextField.tintColor` is nullable, so fall back to the system tint.
        let color = tintColor ?? .systemBlue
        UIView.animate(withDuration: 0.2) {
            self.layer.borderWidth = visible ? 1.5 : 0
            self.layer.borderColor = color.cgColor
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        layer.borderColor = (tintColor ?? .systemBlue).cgColor
    }

    // MARK: Text insets

    override func textRect(forBounds bounds: CGRect) -> CGRect {
        bounds.inset(by: UIEdgeInsets(top: 0, left: Self.textPadding,
                                      bottom: 0, right: Self.textPadding))
    }

    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        textRect(forBounds: bounds)
    }

    override func placeholderRect(forBounds bounds: CGRect) -> CGRect {
        textRect(forBounds: bounds)
    }
}

/// A label that wraps onto several lines.
///
/// `UILabel` only reports a multi-line intrinsic height once `preferredMaxLayoutWidth`
/// is set, so a plain label inside a stack view is laid out one line high and
/// truncates its text instead of wrapping it.
class WrappingLabel: UILabel {

    override init(frame: CGRect) {
        super.init(frame: frame)
        numberOfLines = 0
        lineBreakMode = .byWordWrapping
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard preferredMaxLayoutWidth != bounds.width else { return }
        preferredMaxLayoutWidth = bounds.width
        invalidateIntrinsicContentSize()
    }
}

/// A label with internal padding and a matching intrinsic size, used for badges and toasts.
final class BadgeLabel: WrappingLabel {

    var contentInsets = UIEdgeInsets(top: 2, left: 7, bottom: 2, right: 7) {
        didSet { invalidateIntrinsicContentSize() }
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: contentInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + contentInsets.left + contentInsets.right,
                      height: size.height + contentInsets.top + contentInsets.bottom)
    }
}

/// A centred placeholder used for loading, error and empty states.
final class MessageView: UIView {

    private let stack = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = WrappingLabel()
    private let messageLabel = WrappingLabel()
    private let actionButton = UIButton(type: .system)

    var onAction: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(title: String, message: String? = nil, loading: Bool = false,
                   actionTitle: String? = nil, onAction: (() -> Void)? = nil) {
        titleLabel.text = title
        messageLabel.text = message
        messageLabel.isHidden = message == nil
        actionButton.isHidden = actionTitle == nil
        actionButton.setTitle(actionTitle, for: .normal)
        self.onAction = onAction
        if loading {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        spinner.isHidden = !loading
    }

    private func setup() {
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        spinner.hidesWhenStopped = true

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        actionButton.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)

        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(messageLabel)
        stack.addArrangedSubview(actionButton)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
    }

    @objc private func actionTapped() {
        onAction?()
    }
}
