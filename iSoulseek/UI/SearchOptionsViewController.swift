import UIKit

/// The filters behind the search screen's cog. Changes are reported immediately so the results
/// behind the card update as the user types; dismissing is only a matter of closing the card.
final class SearchOptionsViewController: UIViewController, FloatingSheetContent {

    private enum Metrics {
        static let horizontal: CGFloat = 20
        static let fieldHeight: CGFloat = 44
        static let rowHeight: CGFloat = 48
        static let cornerRadius: CGFloat = 12
        static let cardCornerRadius: CGFloat = 28
        static let dragAreaHeight: CGFloat = 36
    }

    private let sheetTransition = FloatingSheetTransitioningDelegate()
    private let onChange: (SearchOptions) -> Void
    private var options: SearchOptions

    private let cardView = UIView()
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let resetButton = UIButton(type: .system)
    private var contentWidthConstraint: NSLayoutConstraint?

    private let fileTypesField = InsetTextField()
    private let excludedWordsField = InsetTextField()
    private let minimumSizeField = InsetTextField()
    private let maximumSizeField = InsetTextField()
    private let bitrateButton = UIButton(type: .system)
    private let losslessSwitch = UISwitch()
    private let freeSlotsSwitch = UISwitch()
    private let doneButton = UIButton(type: .system)
    private var bitrateRow: UIView?

    private lazy var numberToolbar: UIToolbar = {
        let toolbar = UIToolbar()
        toolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(dismissKeyboard)),
        ]
        toolbar.sizeToFit()
        return toolbar
    }()

    init(options: SearchOptions, onChange: @escaping (SearchOptions) -> Void) {
        self.options = options
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .custom
        transitioningDelegate = sheetTransition
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        buildContent()
        updateFields()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.shadowPath = UIBezierPath(roundedRect: view.bounds,
                                             cornerRadius: Metrics.cardCornerRadius).cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        cardView.layer.borderColor = UIColor.separator.cgColor
        if previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory {
            presentationController?.containerView?.setNeedsLayout()
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss(animated: true)
        return true
    }

    func preferredSheetHeight(forWidth width: CGFloat) -> CGFloat {
        loadViewIfNeeded()
        let width = width - Metrics.horizontal * 2
        contentWidthConstraint?.constant = width
        let fitting = contentStack.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        // Handle area, scroll content top padding and bottom padding.
        return Metrics.dragAreaHeight + 8 + fitting.height + 20
    }

    // MARK: Setup

    private func configureView() {
        view.backgroundColor = .clear
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.24
        view.layer.shadowRadius = 28
        view.layer.shadowOffset = CGSize(width: 0, height: 12)

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = .systemBackground
        cardView.layer.cornerRadius = Metrics.cardCornerRadius
        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 0.5
        cardView.layer.borderColor = UIColor.separator.cgColor
        cardView.clipsToBounds = true
        view.addSubview(cardView)

        let handle = UIView()
        handle.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(handle)

        let grabber = UIView()
        grabber.translatesAutoresizingMaskIntoConstraints = false
        grabber.backgroundColor = .tertiaryLabel
        grabber.alpha = 0.5
        grabber.layer.cornerRadius = 2.5
        grabber.isAccessibilityElement = false
        handle.addSubview(grabber)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        scrollView.keyboardDismissMode = .interactive
        cardView.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: view.topAnchor),
            cardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cardView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            handle.topAnchor.constraint(equalTo: cardView.topAnchor),
            handle.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            handle.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            handle.heightAnchor.constraint(equalToConstant: Metrics.dragAreaHeight),

            grabber.centerXAnchor.constraint(equalTo: handle.centerXAnchor),
            grabber.centerYAnchor.constraint(equalTo: handle.centerYAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 36),
            grabber.heightAnchor.constraint(equalToConstant: 5),

            scrollView.topAnchor.constraint(equalTo: handle.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 8),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                                                  constant: Metrics.horizontal),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                                                   constant: -Metrics.horizontal),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20),
        ])

        let width = contentStack.widthAnchor.constraint(equalToConstant: 320)
        width.isActive = true
        contentWidthConstraint = width
    }

    private func buildContent() {
        let header = makeHeader()
        contentStack.addArrangedSubview(header)
        contentStack.setCustomSpacing(2, after: header)

        let subtitle = makeHelper("Changes apply to results immediately.")
        contentStack.addArrangedSubview(subtitle)
        contentStack.setCustomSpacing(20, after: subtitle)

        addSection("File types")
        configure(fileTypesField, placeholder: "Any file type", keyboard: .default)
        fileTypesField.autocapitalizationType = .none
        fileTypesField.autocorrectionType = .no
        fileTypesField.returnKeyType = .done
        fileTypesField.delegate = self
        fileTypesField.addTarget(self, action: #selector(fileTypesChanged), for: .editingChanged)
        fileTypesField.addTarget(self, action: #selector(normalizeFields), for: .editingDidEnd)
        addField(fileTypesField)
        addHelper("Only these types are shown. Comma-separated, e.g. flac, m4a, mp3.",
                  spacingAfter: 20)

        addSection("Exclude words")
        configure(excludedWordsField, placeholder: "None", keyboard: .default)
        excludedWordsField.autocapitalizationType = .none
        excludedWordsField.autocorrectionType = .no
        excludedWordsField.returnKeyType = .done
        excludedWordsField.delegate = self
        excludedWordsField.addTarget(self, action: #selector(excludedWordsChanged), for: .editingChanged)
        excludedWordsField.addTarget(self, action: #selector(normalizeFields), for: .editingDidEnd)
        addField(excludedWordsField)
        addHelper("Hides results whose path contains any of these words.", spacingAfter: 20)

        addSection("Size")
        minimumSizeField.placeholder = "Min MB"
        maximumSizeField.placeholder = "Max MB"
        for field in [minimumSizeField, maximumSizeField] {
            configure(field, placeholder: field.placeholder ?? "", keyboard: .numberPad)
            field.inputAccessoryView = numberToolbar
            field.delegate = self
            field.addTarget(self, action: #selector(sizeChanged), for: .editingChanged)
            field.addTarget(self, action: #selector(normalizeFields), for: .editingDidEnd)
        }
        let sizeRow = UIStackView(arrangedSubviews: [minimumSizeField, maximumSizeField])
        sizeRow.axis = .horizontal
        sizeRow.distribution = .fillEqually
        sizeRow.spacing = 10
        contentStack.addArrangedSubview(sizeRow)
        contentStack.setCustomSpacing(6, after: sizeRow)
        addHelper("Optional, in megabytes. Leave either field empty for no limit.", spacingAfter: 20)

        addSection("Quality")
        let losslessRow = makeLosslessRow()
        contentStack.addArrangedSubview(losslessRow)
        contentStack.setCustomSpacing(6, after: losslessRow)
        addHelper("FLAC, WAV, ALAC and other lossless formats.", spacingAfter: 8)

        let bitrateRow = makeBitrateRow()
        self.bitrateRow = bitrateRow
        contentStack.addArrangedSubview(bitrateRow)
        contentStack.setCustomSpacing(6, after: bitrateRow)
        addHelper("Files without bitrate information are hidden.", spacingAfter: 8)

        let freeSlotsRow = makeFreeSlotsRow()
        contentStack.addArrangedSubview(freeSlotsRow)
        contentStack.setCustomSpacing(6, after: freeSlotsRow)
        addHelper("Only users ready to start a download right now.", spacingAfter: 24)

        contentStack.addArrangedSubview(makeDoneButton())
    }

    private func makeHeader() -> UIView {
        let title = UILabel()
        title.text = "Search Options"
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true
        title.accessibilityTraits = .header

        var configuration = UIButton.Configuration.plain()
        configuration.title = "Reset"
        configuration.contentInsets = .zero
        resetButton.configuration = configuration
        resetButton.addTarget(self, action: #selector(resetOptions), for: .touchUpInside)
        resetButton.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [title, resetButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        return row
    }

    private func addSection(_ title: String) {
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.accessibilityTraits = .header
        contentStack.addArrangedSubview(label)
        contentStack.setCustomSpacing(6, after: label)
    }

    private func addField(_ field: UITextField) {
        contentStack.addArrangedSubview(field)
        contentStack.setCustomSpacing(6, after: field)
        field.heightAnchor.constraint(equalToConstant: Metrics.fieldHeight).isActive = true
    }

    private func addHelper(_ text: String, spacingAfter: CGFloat) {
        let label = makeHelper(text)
        contentStack.addArrangedSubview(label)
        contentStack.setCustomSpacing(spacingAfter, after: label)
    }

    private func makeHelper(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .tertiaryLabel
        label.numberOfLines = 0
        return label
    }

    private func configure(_ field: InsetTextField, placeholder: String, keyboard: UIKeyboardType) {
        field.placeholder = placeholder
        field.keyboardType = keyboard
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
    }

    private func makeBitrateRow() -> UIView {
        let label = UILabel()
        label.text = "Minimum bitrate"
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true

        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "chevron.up.chevron.down")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 6
        configuration.contentInsets = .zero
        bitrateButton.configuration = configuration
        bitrateButton.showsMenuAsPrimaryAction = true
        bitrateButton.setContentHuggingPriority(.required, for: .horizontal)
        updateBitrateMenu()

        let row = makeGroupedRow(label, accessory: bitrateButton)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.rowHeight).isActive = true
        return row
    }

    private func makeFreeSlotsRow() -> UIView {
        let label = UILabel()
        label.text = "Only free upload slots"
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true

        freeSlotsSwitch.isOn = options.requiresFreeSlot
        freeSlotsSwitch.addTarget(self, action: #selector(freeSlotsChanged), for: .valueChanged)

        let row = makeGroupedRow(label, accessory: freeSlotsSwitch)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.rowHeight).isActive = true
        return row
    }

    private func makeLosslessRow() -> UIView {
        let label = UILabel()
        label.text = "Lossless only"
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true

        losslessSwitch.isOn = options.requiresLossless
        losslessSwitch.addTarget(self, action: #selector(losslessChanged), for: .valueChanged)

        let row = makeGroupedRow(label, accessory: losslessSwitch)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.rowHeight).isActive = true
        return row
    }

    private func makeGroupedRow(_ label: UILabel, accessory: UIView) -> UIStackView {
        let row = UIStackView(arrangedSubviews: [label, UIView(), accessory])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 12)
        row.backgroundColor = .secondarySystemBackground
        row.layer.cornerRadius = Metrics.cornerRadius
        row.layer.cornerCurve = .continuous
        row.clipsToBounds = true
        return row
    }

    private func makeDoneButton() -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = "Done"
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        doneButton.configuration = configuration
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        return doneButton
    }

    private func updateBitrateMenu() {
        var actions = [UIAction(title: "Any bitrate",
                                state: options.minimumBitrate == nil ? .on : .off) { [weak self] _ in
            self?.setMinimumBitrate(nil)
        }]
        actions.append(contentsOf: SearchOptions.bitrateChoices.map { choice in
            UIAction(title: "\(choice) kbps or higher",
                     state: options.minimumBitrate == choice ? .on : .off) { [weak self] _ in
                self?.setMinimumBitrate(choice)
            }
        })
        bitrateButton.menu = UIMenu(children: actions)
        bitrateButton.configuration?.title = options.minimumBitrate.map { "\($0) kbps" } ?? "Any"
    }

    // MARK: Values

    private func updateFields() {
        fileTypesField.text = options.fileTypes.joined(separator: ", ")
        excludedWordsField.text = options.excludedWords.joined(separator: ", ")
        minimumSizeField.text = options.minimumSizeMB.map(String.init) ?? ""
        maximumSizeField.text = options.maximumSizeMB.map(String.init) ?? ""
        losslessSwitch.isOn = options.requiresLossless
        freeSlotsSwitch.isOn = options.requiresFreeSlot
        updateBitrateMenu()
        updateBitrateAvailability()
        resetButton.isEnabled = options.isActive
    }

    private func updateBitrateAvailability() {
        let available = !options.requiresLossless
        bitrateButton.isEnabled = available
        bitrateRow?.alpha = available ? 1 : 0.4
    }

    private func notifyChange() {
        resetButton.isEnabled = options.isActive
        onChange(options)
    }

    private func setMinimumBitrate(_ bitrate: UInt32?) {
        options.minimumBitrate = bitrate
        updateBitrateMenu()
        notifyChange()
    }

    private static func sizeMB(from text: String?) -> Int? {
        guard let value = Int((text ?? "").trimmingCharacters(in: .whitespaces)), value > 0 else {
            return nil
        }
        return min(value, SearchOptions.maximumSizeMB)
    }

    // MARK: Actions

    @objc private func fileTypesChanged() {
        options.fileTypes = SearchOptions.parseWords(fileTypesField.text ?? "")
        notifyChange()
    }

    @objc private func excludedWordsChanged() {
        options.excludedWords = SearchOptions.parseWords(excludedWordsField.text ?? "")
        notifyChange()
    }

    @objc private func sizeChanged() {
        options.minimumSizeMB = Self.sizeMB(from: minimumSizeField.text)
        options.maximumSizeMB = Self.sizeMB(from: maximumSizeField.text)
        notifyChange()
    }

    @objc private func freeSlotsChanged() {
        options.requiresFreeSlot = freeSlotsSwitch.isOn
        notifyChange()
    }

    @objc private func losslessChanged() {
        options.requiresLossless = losslessSwitch.isOn
        if losslessSwitch.isOn {
            options.minimumBitrate = nil
            updateBitrateMenu()
        }
        updateBitrateAvailability()
        notifyChange()
    }

    @objc private func resetOptions() {
        options = SearchOptions()
        updateFields()
        notifyChange()
    }

    @objc private func normalizeFields() {
        fileTypesField.text = options.fileTypes.joined(separator: ", ")
        excludedWordsField.text = options.excludedWords.joined(separator: ", ")
        minimumSizeField.text = options.minimumSizeMB.map(String.init) ?? ""
        maximumSizeField.text = options.maximumSizeMB.map(String.init) ?? ""
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    @objc private func doneTapped() {
        view.endEditing(true)
        dismiss(animated: true)
    }
}

// MARK: - UITextFieldDelegate

extension SearchOptionsViewController: UITextFieldDelegate {

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

private extension UIFont {

    /// `UIFont.systemFont(ofSize:weight:)` is convenient but loses the text-style scaling that
    /// `preferredFont(forTextStyle:)` provides, so apply a weight to the scaled descriptor.
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
