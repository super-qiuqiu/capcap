import AppKit

final class PresetSettingsPane: NSView {
    private var presets: [SizePreset] = []
    private let stack = NSStackView()
    private let listStack = NSStackView()
    private let addButton = NSButton()
    private let limitLabel = NSTextField(wrappingLabelWithString: "")
    private var editWindow: NSWindow?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        reloadPresets()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onPresetsChanged),
            name: .sizePresetsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onLanguageChanged),
            name: .languageDidChange,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func buildUI() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let listCard = PresetSettingsCard()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listCard.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.topAnchor.constraint(equalTo: listCard.topAnchor, constant: 4),
            listStack.leadingAnchor.constraint(equalTo: listCard.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: listCard.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: listCard.bottomAnchor, constant: -4),
        ])
        stack.addArrangedSubview(listCard)
        listCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        limitLabel.font = NSFont.systemFont(ofSize: 11)
        limitLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        limitLabel.maximumNumberOfLines = 2
        limitLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(limitLabel)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        footer.addArrangedSubview(spacer)

        addButton.bezelStyle = .rounded
        addButton.controlSize = .large
        addButton.target = self
        addButton.action = #selector(addPresetClicked)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.setContentHuggingPriority(.required, for: .horizontal)
        footer.addArrangedSubview(addButton)

        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
        ])

        applyLocalizedStrings()
    }

    private func reloadPresets() {
        presets = Defaults.sizePresets
        rebuildRows()
        refreshLimitState()
    }

    private func rebuildRows() {
        for view in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (index, preset) in presets.enumerated() {
            let row = PresetSettingsRow(preset: preset)
            row.onEdit = { [weak self] in self?.editPreset(preset) }
            row.onDelete = { [weak self] in self?.deletePreset(preset) }
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true

            if index < presets.count - 1 {
                let divider = PresetSettingsDivider()
                listStack.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            }
        }
    }

    private func refreshLimitState() {
        let customCount = presets.filter { !$0.isBuiltIn }.count
        let canAdd = customCount < SizePreset.maxCustomPresetCount
        addButton.isEnabled = canAdd
        addButton.alphaValue = canAdd ? 1.0 : 0.55
        limitLabel.isHidden = canAdd
        limitLabel.stringValue = canAdd ? "" : L10n.presetLimitReached
    }

    private func applyLocalizedStrings() {
        addButton.title = L10n.presetSettingsAddButton
        refreshLimitState()
    }

    @objc private func addPresetClicked() {
        guard presets.filter({ !$0.isBuiltIn }).count < SizePreset.maxCustomPresetCount else {
            return
        }
        let newPreset = SizePreset.makeDefaultCustomPreset(name: L10n.presetFormDefaultName)
        showEditSheet(for: newPreset, isNew: true)
    }

    private func editPreset(_ preset: SizePreset) {
        guard !preset.isBuiltIn else { return }
        showEditSheet(for: preset, isNew: false)
    }

    private func deletePreset(_ preset: SizePreset) {
        presets.removeAll { $0.id == preset.id }
        Defaults.sizePresets = presets
        reloadPresets()
    }

    private func showEditSheet(for preset: SizePreset, isNew: Bool) {
        let formView = PresetFormView(preset: preset, isNew: isNew) { [weak self] updatedPreset in
            self?.savePreset(updatedPreset, isNew: isNew)
            self?.dismissEditSheet()
        } onCancel: { [weak self] in
            self?.dismissEditSheet()
        } onDelete: { [weak self] in
            self?.deletePreset(preset)
            self?.dismissEditSheet()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = isNew ? L10n.presetFormWindowTitleAdd : L10n.presetFormWindowTitleEdit
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.17, alpha: 1.0)
        window.contentView = formView

        guard let parentWindow = self.window else { return }
        parentWindow.beginSheet(window)
        editWindow = window
    }

    private func dismissEditSheet() {
        guard let window = editWindow else { return }
        window.sheetParent?.endSheet(window)
        editWindow = nil
    }

    private func savePreset(_ preset: SizePreset, isNew: Bool) {
        if isNew {
            presets.append(preset)
        } else if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        }
        Defaults.sizePresets = presets
        reloadPresets()
    }

    @objc private func onPresetsChanged() {
        reloadPresets()
    }

    @objc private func onLanguageChanged() {
        applyLocalizedStrings()
        rebuildRows()
    }
}

private final class PresetSettingsRow: NSView {
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    private let preset: SizePreset
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let editButton = NSButton()
    private let deleteButton = NSButton()

    init(preset: SizePreset) {
        self.preset = preset
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        applyPreset()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = NSColor.white.withAlphaComponent(0.94)
        nameLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.56)
        detailLabel.lineBreakMode = .byTruncatingTail
        textStack.addArrangedSubview(nameLabel)
        textStack.addArrangedSubview(detailLabel)

        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.setContentHuggingPriority(.required, for: .horizontal)

        configureButton(editButton, action: #selector(editClicked))
        configureButton(deleteButton, action: #selector(deleteClicked))
        buttonStack.addArrangedSubview(editButton)
        buttonStack.addArrangedSubview(deleteButton)

        addSubview(textStack)
        addSubview(buttonStack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 56),

            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -12),

            buttonStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            buttonStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            editButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 68),
            deleteButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
        ])
    }

    private func configureButton(_ button: NSButton, action: Selector) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func applyPreset() {
        nameLabel.stringValue = preset.name
        switch preset.constraint {
        case .fixedSize:
            detailLabel.stringValue = "\(L10n.presetFormFixedSize) · \(preset.constraint.displayName)"
        case .aspectRatio:
            detailLabel.stringValue = "\(L10n.presetFormAspectRatio) · \(preset.constraint.displayName)"
        }
        editButton.title = L10n.presetFormEditButton
        deleteButton.title = L10n.presetFormDeleteButton

        let canEdit = !preset.isBuiltIn
        editButton.isEnabled = canEdit
        editButton.alphaValue = canEdit ? 1.0 : 0.45
        deleteButton.isEnabled = true
        deleteButton.alphaValue = 1.0
    }

    @objc private func editClicked() {
        onEdit?()
    }

    @objc private func deleteClicked() {
        onDelete?()
    }
}

private final class PresetFormView: NSView, NSTextFieldDelegate {
    private enum EditedDimension {
        case width
        case height
    }

    private enum PresetMode {
        case fixedSize
        case aspectRatio
    }

    private let nameLabel = NSTextField(labelWithString: "")
    private let modeLabel = NSTextField(labelWithString: "")
    private let widthLabel = NSTextField(labelWithString: "")
    private let heightLabel = NSTextField(labelWithString: "")
    private let ratioLabel = NSTextField(labelWithString: "")
    private let currentRatioLabel = NSTextField(labelWithString: "")
    private let commonRatiosLabel = NSTextField(labelWithString: "")
    private let nameField = NSTextField()
    private let modeControl = NSSegmentedControl()
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let widthStepper = NSStepper()
    private let heightStepper = NSStepper()
    private let widthUnitLabel = NSTextField(labelWithString: "")
    private let heightUnitLabel = NSTextField(labelWithString: "")
    private let lockRatioButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let ratioButtonsStack = NSStackView()
    private let saveButton = NSButton()
    private let cancelButton = NSButton()
    private let deleteButton = NSButton()
    private var lockRatioRow: NSGridRow?

    private static let commonRatios: [(title: String, width: Int, height: Int)] = [
        ("1:1", 1, 1),
        ("4:3", 4, 3),
        ("3:2", 3, 2),
        ("16:9", 16, 9),
        ("9:16", 9, 16),
        ("21:9", 21, 9)
    ]

    private var isUpdatingFields = false
    private var lockedRatio: (width: Int, height: Int) = (16, 9)
    private var lastEditedDimension: EditedDimension = .width

    private var preset: SizePreset
    private let isNew: Bool
    private let onSave: (SizePreset) -> Void
    private let onCancel: () -> Void
    private let onDelete: () -> Void

    init(
        preset: SizePreset,
        isNew: Bool,
        onSave: @escaping (SizePreset) -> Void,
        onCancel: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.preset = preset
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        applyLocalizedStrings()
        populateFields()
        refreshSaveEnabled()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onLanguageChanged),
            name: .languageDidChange,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private var currentMode: PresetMode {
        modeControl.selectedSegment == 1 ? .aspectRatio : .fixedSize
    }

    private func buildUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        configureTextField(nameField, minWidth: 230)
        configureNumberField(widthField, maxValue: 20000, minWidth: 92)
        configureNumberField(heightField, maxValue: 20000, minWidth: 92)
        configureStepper(widthStepper, maxValue: 20000, action: #selector(dimensionStepperChanged))
        configureStepper(heightStepper, maxValue: 20000, action: #selector(dimensionStepperChanged))

        lockRatioButton.target = self
        lockRatioButton.action = #selector(lockRatioToggled)
        lockRatioButton.controlSize = .small
        lockRatioButton.translatesAutoresizingMaskIntoConstraints = false
        configureRatioButtons()
        configureModeControl()

        let grid = NSGridView(views: [
            [nameLabel, nameField],
            [modeLabel, modeControl],
            [widthLabel, makeDimensionControl(field: widthField, stepper: widthStepper, unitLabel: widthUnitLabel)],
            [heightLabel, makeDimensionControl(field: heightField, stepper: heightStepper, unitLabel: heightUnitLabel)],
            [ratioLabel, currentRatioLabel],
            [NSView(), lockRatioButton],
            [commonRatiosLabel, ratioButtonsStack],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.xPlacement = .fill
        grid.yPlacement = .center
        grid.column(at: 0).width = 92
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        lockRatioRow = grid.row(at: 5)

        for label in [nameLabel, modeLabel, widthLabel, heightLabel, ratioLabel, commonRatiosLabel] {
            label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            label.textColor = NSColor.white.withAlphaComponent(0.74)
        }
        currentRatioLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        currentRatioLabel.textColor = NSColor.white.withAlphaComponent(0.84)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        configureButton(deleteButton, action: #selector(deleteClicked))
        deleteButton.isHidden = isNew
        buttonRow.addArrangedSubview(deleteButton)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        buttonRow.addArrangedSubview(spacer)

        configureButton(cancelButton, action: #selector(cancelClicked))
        configureButton(saveButton, action: #selector(saveClicked))
        saveButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(saveButton)

        addSubview(grid)
        addSubview(buttonRow)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

            buttonRow.topAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 20),
            buttonRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            buttonRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            buttonRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
        ])
    }

    private func configureButton(_ button: NSButton, action: Selector) {
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func configureTextField(_ field: NSTextField, minWidth: CGFloat) {
        field.delegate = self
        field.controlSize = .large
        field.font = NSFont.systemFont(ofSize: 13)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
    }

    private func configureNumberField(_ field: NSTextField, maxValue: Int, minWidth: CGFloat) {
        configureTextField(field, minWidth: minWidth)
        field.alignment = .right
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1
        formatter.maximum = NSNumber(value: maxValue)
        formatter.allowsFloats = false
        formatter.usesGroupingSeparator = false
        field.formatter = formatter
    }

    private func configureStepper(_ stepper: NSStepper, maxValue: Double, action: Selector) {
        stepper.minValue = 1
        stepper.maxValue = maxValue
        stepper.increment = 1
        stepper.autorepeat = true
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = action
        stepper.translatesAutoresizingMaskIntoConstraints = false
    }

    private func makeDimensionControl(field: NSTextField, stepper: NSStepper, unitLabel: NSTextField) -> NSView {
        unitLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        unitLabel.textColor = NSColor.white.withAlphaComponent(0.56)
        unitLabel.alignment = .left

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(field)
        stack.addArrangedSubview(stepper)
        stack.addArrangedSubview(unitLabel)
        unitLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 22).isActive = true
        return stack
    }

    private func configureModeControl() {
        modeControl.segmentCount = 2
        modeControl.selectedSegment = 0
        modeControl.trackingMode = .selectOne
        modeControl.controlSize = .large
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
    }

    private func configureRatioButtons() {
        ratioButtonsStack.orientation = .horizontal
        ratioButtonsStack.alignment = .centerY
        ratioButtonsStack.spacing = 6
        ratioButtonsStack.translatesAutoresizingMaskIntoConstraints = false
        ratioButtonsStack.setContentHuggingPriority(.required, for: .horizontal)

        for (index, ratio) in Self.commonRatios.enumerated() {
            let button = NSButton(title: ratio.title, target: self, action: #selector(commonRatioClicked))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.tag = index
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
            ratioButtonsStack.addArrangedSubview(button)
        }
    }

    private func populateFields() {
        isUpdatingFields = true
        nameField.stringValue = preset.name
        lockRatioButton.state = .on
        switch preset.constraint {
        case .fixedSize(let width, let height):
            selectMode(.fixedSize)
            widthField.stringValue = "\(width)"
            heightField.stringValue = "\(height)"
            lockedRatio = reducedRatio(width: width, height: height)
        case .aspectRatio(let width, let height):
            let ratio = reducedRatio(width: width, height: height)
            selectMode(.aspectRatio)
            widthField.stringValue = "\(ratio.width)"
            heightField.stringValue = "\(ratio.height)"
            lockedRatio = ratio
        }
        syncSteppers()
        isUpdatingFields = false
        refreshModeState()
        refreshRatioButtons()
    }

    private func applyLocalizedStrings() {
        nameLabel.stringValue = L10n.presetFormNameLabel
        modeLabel.stringValue = L10n.presetFormTypeLabel
        modeControl.setLabel(L10n.presetFormFixedSize, forSegment: 0)
        modeControl.setLabel(L10n.presetFormAspectRatio, forSegment: 1)
        widthLabel.stringValue = L10n.presetFormWidthLabel
        heightLabel.stringValue = L10n.presetFormHeightLabel
        ratioLabel.stringValue = L10n.presetFormRatioLabel
        commonRatiosLabel.stringValue = L10n.presetFormCommonRatios
        nameField.placeholderString = L10n.presetFormNamePlaceholder

        widthUnitLabel.stringValue = L10n.presetFormPixelsUnit
        heightUnitLabel.stringValue = L10n.presetFormPixelsUnit
        lockRatioButton.title = L10n.presetFormLockRatio
        saveButton.title = L10n.presetFormSaveButton
        cancelButton.title = L10n.presetFormCancelButton
        deleteButton.title = L10n.presetFormDeleteButton
        window?.title = isNew ? L10n.presetFormWindowTitleAdd : L10n.presetFormWindowTitleEdit
        refreshModeState()
        refreshRatioButtons()
    }

    private func currentPresetFromFields() -> SizePreset? {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let width = positiveInt(from: widthField),
              let height = positiveInt(from: heightField)
        else { return nil }

        return SizePreset(
            id: preset.id,
            name: name,
            constraint: makeConstraint(width: width, height: height),
            isBuiltIn: preset.isBuiltIn
        )
    }

    private func makeConstraint(width: Int, height: Int) -> SizeConstraint {
        switch currentMode {
        case .fixedSize:
            return .fixedSize(width: width, height: height)
        case .aspectRatio:
            let ratio = reducedRatio(width: width, height: height)
            return .aspectRatio(width: ratio.width, height: ratio.height)
        }
    }

    private func refreshSaveEnabled() {
        saveButton.isEnabled = currentPresetFromFields() != nil
    }

    private func positiveInt(from field: NSTextField) -> Int? {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let intValue = Int(value), intValue > 0 else { return nil }
        return intValue
    }

    private func reducedRatio(width: Int, height: Int) -> (width: Int, height: Int) {
        var a = max(abs(width), 1)
        var b = max(abs(height), 1)
        var remainder = a % b
        while remainder != 0 {
            a = b
            b = remainder
            remainder = a % b
        }
        let divisor = max(b, 1)
        return (max(abs(width), 1) / divisor, max(abs(height), 1) / divisor)
    }

    private func syncLockedRatioFromDimensions() {
        if let width = positiveInt(from: widthField),
           let height = positiveInt(from: heightField) {
            lockedRatio = reducedRatio(width: width, height: height)
        }
        refreshRatioButtons()
    }

    private func selectMode(_ mode: PresetMode) {
        modeControl.selectedSegment = mode == .fixedSize ? 0 : 1
    }

    private func ratioFromFieldsOrLocked() -> (width: Int, height: Int) {
        if let width = positiveInt(from: widthField),
           let height = positiveInt(from: heightField) {
            return reducedRatio(width: width, height: height)
        }
        return lockedRatio
    }

    private func refreshModeState() {
        let isFixedSize = currentMode == .fixedSize
        lockRatioRow?.isHidden = !isFixedSize
        widthUnitLabel.stringValue = isFixedSize ? L10n.presetFormPixelsUnit : ""
        heightUnitLabel.stringValue = isFixedSize ? L10n.presetFormPixelsUnit : ""
        widthUnitLabel.isHidden = !isFixedSize
        heightUnitLabel.isHidden = !isFixedSize
        lockRatioButton.isEnabled = isFixedSize
        refreshRatioButtons()
    }

    private func syncSteppers() {
        if let width = positiveInt(from: widthField) {
            widthStepper.integerValue = width
        }
        if let height = positiveInt(from: heightField) {
            heightStepper.integerValue = height
        }
    }

    private func applyRatioLock(changed dimension: EditedDimension) {
        guard currentMode == .fixedSize, lockRatioButton.state == .on else { return }

        isUpdatingFields = true
        switch dimension {
        case .width:
            if let width = positiveInt(from: widthField) {
                let height = max(1, Int((Double(width) * Double(lockedRatio.height) / Double(lockedRatio.width)).rounded()))
                heightField.stringValue = "\(height)"
            }
        case .height:
            if let height = positiveInt(from: heightField) {
                let width = max(1, Int((Double(height) * Double(lockedRatio.width) / Double(lockedRatio.height)).rounded()))
                widthField.stringValue = "\(width)"
            }
        }
        syncSteppers()
        isUpdatingFields = false
        refreshRatioButtons()
        refreshSaveEnabled()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !isUpdatingFields else { return }
        if let field = obj.object as? NSTextField {
            if field === widthField {
                lastEditedDimension = .width
                if currentMode == .fixedSize, lockRatioButton.state == .on {
                    applyRatioLock(changed: .width)
                } else {
                    syncLockedRatioFromDimensions()
                }
            } else if field === heightField {
                lastEditedDimension = .height
                if currentMode == .fixedSize, lockRatioButton.state == .on {
                    applyRatioLock(changed: .height)
                } else {
                    syncLockedRatioFromDimensions()
                }
            }
        }
        refreshSaveEnabled()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isUpdatingFields else { return }
        guard let field = obj.object as? NSTextField else {
            refreshSaveEnabled()
            return
        }

        if field === widthField {
            lastEditedDimension = .width
            if currentMode == .fixedSize, lockRatioButton.state == .on {
                applyRatioLock(changed: .width)
            } else {
                syncLockedRatioFromDimensions()
            }
        } else if field === heightField {
            lastEditedDimension = .height
            if currentMode == .fixedSize, lockRatioButton.state == .on {
                applyRatioLock(changed: .height)
            } else {
                syncLockedRatioFromDimensions()
            }
        }
        syncSteppers()
        refreshSaveEnabled()
    }

    @objc private func dimensionStepperChanged(_ sender: NSStepper) {
        guard !isUpdatingFields else { return }
        if sender === widthStepper {
            lastEditedDimension = .width
            widthField.stringValue = "\(sender.integerValue)"
            applyRatioLock(changed: .width)
        } else if sender === heightStepper {
            lastEditedDimension = .height
            heightField.stringValue = "\(sender.integerValue)"
            applyRatioLock(changed: .height)
        }
        if currentMode == .aspectRatio || lockRatioButton.state == .off {
            syncLockedRatioFromDimensions()
        }
        refreshSaveEnabled()
    }

    @objc private func lockRatioToggled() {
        if lockRatioButton.state == .on {
            syncLockedRatioFromDimensions()
        }
        refreshRatioButtons()
        refreshSaveEnabled()
    }

    @objc private func commonRatioClicked(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < Self.commonRatios.count else { return }
        let ratio = Self.commonRatios[sender.tag]
        lockedRatio = reducedRatio(width: ratio.width, height: ratio.height)
        switch currentMode {
        case .fixedSize:
            lockRatioButton.state = .on
            applyRatioLock(changed: lastEditedDimension)
        case .aspectRatio:
            isUpdatingFields = true
            widthField.stringValue = "\(lockedRatio.width)"
            heightField.stringValue = "\(lockedRatio.height)"
            syncSteppers()
            isUpdatingFields = false
        }
        refreshRatioButtons()
        refreshSaveEnabled()
    }

    @objc private func modeChanged() {
        let ratio = ratioFromFieldsOrLocked()
        lockedRatio = ratio
        isUpdatingFields = true
        switch currentMode {
        case .fixedSize:
            let baseWidth = 1920
            let baseHeight = max(1, Int((Double(baseWidth) * Double(ratio.height) / Double(ratio.width)).rounded()))
            widthField.stringValue = "\(baseWidth)"
            heightField.stringValue = "\(baseHeight)"
            lockRatioButton.state = .on
            lastEditedDimension = .width
        case .aspectRatio:
            widthField.stringValue = "\(ratio.width)"
            heightField.stringValue = "\(ratio.height)"
            lastEditedDimension = .width
        }
        syncSteppers()
        isUpdatingFields = false
        refreshModeState()
        refreshSaveEnabled()
    }

    private func refreshRatioButtons() {
        let activeRatio = "\(lockedRatio.width):\(lockedRatio.height)"
        for case let button as NSButton in ratioButtonsStack.arrangedSubviews {
            let isActive = button.title == activeRatio &&
                (currentMode == .aspectRatio || lockRatioButton.state == .on)
            button.state = isActive ? .on : .off
        }
        refreshCurrentRatioLabel()
    }

    private func refreshCurrentRatioLabel() {
        if currentMode == .fixedSize, lockRatioButton.state == .on {
            currentRatioLabel.stringValue = "\(lockedRatio.width):\(lockedRatio.height)"
            return
        }

        guard let width = positiveInt(from: widthField),
              let height = positiveInt(from: heightField)
        else {
            currentRatioLabel.stringValue = ""
            return
        }
        let ratio = reducedRatio(width: width, height: height)
        currentRatioLabel.stringValue = "\(ratio.width):\(ratio.height)"
    }

    @objc private func saveClicked() {
        guard let updatedPreset = currentPresetFromFields() else { return }
        onSave(updatedPreset)
    }

    @objc private func cancelClicked() {
        onCancel()
    }

    @objc private func deleteClicked() {
        onDelete()
    }

    @objc private func onLanguageChanged() {
        applyLocalizedStrings()
    }
}

private final class PresetSettingsCard: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.borderWidth = 1
    }
}

private final class PresetSettingsDivider: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }
}
