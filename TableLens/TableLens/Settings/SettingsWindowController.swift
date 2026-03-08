import Cocoa

final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    var onSettingsChanged: ((AppSettings) -> Result<Void, Error>)?
    private var settings: AppSettings
    private let apiKeyRow = ToggleSecureInputRow()
    private let secretKeyRow = ToggleSecureInputRow()
    private let saveDirField = NSTextField(string: "")
    private let hotkeyField = HotkeyRecorderField(string: "")
    private let hotkeyRecordButton = NSButton(title: "录制", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    // NOTE: 防抖定时器，避免每次按键都触发加密保存和热键重注册
    private var saveTimer: Timer?

    init(settings: AppSettings) {
        self.settings = settings
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "表格识别设置"
        super.init(window: window)
        buildUI()
        fillValues()
    }

    required init?(coder: NSCoder) { nil }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
        ])

        stack.addArrangedSubview(makeRow(label: "百度 API Key", customView: apiKeyRow))
        stack.addArrangedSubview(makeRow(label: "百度 Secret Key", customView: secretKeyRow))

        let saveRow = NSStackView()
        saveRow.orientation = .horizontal
        saveRow.spacing = 10
        let saveLabel = makeLabel("Excel 保存目录")
        saveLabel.widthAnchor.constraint(equalToConstant: 120).isActive = true
        saveDirField.delegate = self
        let browse = NSButton(title: "选择…", target: self, action: #selector(selectDirectory))
        browse.controlSize = .large
        browse.widthAnchor.constraint(equalToConstant: 72).isActive = true
        saveRow.addArrangedSubview(saveLabel)
        saveRow.addArrangedSubview(saveDirField)
        saveRow.addArrangedSubview(browse)
        stack.addArrangedSubview(saveRow)

        let hotkeyRow = NSStackView()
        hotkeyRow.orientation = .horizontal
        hotkeyRow.spacing = 10
        let hotkeyLabel = makeLabel("全局热键")
        hotkeyLabel.widthAnchor.constraint(equalToConstant: 120).isActive = true
        hotkeyField.isEditable = false
        hotkeyField.isBezeled = true
        hotkeyField.drawsBackground = true
        hotkeyField.onRecordingChanged = { [weak self] isRecording in
            self?.hotkeyRecordButton.title = isRecording ? "正在录制…" : "录制"
            self?.hotkeyRecordButton.isEnabled = !isRecording
        }
        hotkeyField.onRecord = { [weak self] value in
            guard let self else { return }
            if value == "__INVALID_NO_MODIFIER__" {
                self.statusLabel.stringValue = "热键必须至少包含一个修饰键（⌃/⌘/⌥/⇧）。"
                self.statusLabel.textColor = .systemRed
                self.hotkeyField.stringValue = hotkeyDisplayString(from: self.settings.hotkey)
                return
            }
            if let value {
                self.settings.hotkey = value
                self.hotkeyField.stringValue = hotkeyDisplayString(from: value)
                self.persistChanges()
            } else {
                self.hotkeyField.stringValue = hotkeyDisplayString(from: self.settings.hotkey)
                self.hotkeyRecordButton.title = "录制"
                self.hotkeyRecordButton.isEnabled = true
            }
        }
        hotkeyRecordButton.target = self
        hotkeyRecordButton.action = #selector(startHotkeyRecording)
        hotkeyRow.addArrangedSubview(hotkeyLabel)
        hotkeyRow.addArrangedSubview(hotkeyField)
        hotkeyRow.addArrangedSubview(hotkeyRecordButton)
        stack.addArrangedSubview(hotkeyRow)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "点击“录制”，然后直接按新的组合键；不允许无修饰键。"
        stack.addArrangedSubview(statusLabel)

        saveDirField.delegate = self
        apiKeyRow.onChange = { [weak self] _ in self?.schedulePersistChanges() }
        secretKeyRow.onChange = { [weak self] _ in self?.schedulePersistChanges() }
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .left
        return label
    }

    private func makeRow(label text: String, field: NSTextField) -> NSView {
        makeRow(label: text, customView: field)
    }

    private func makeRow(label text: String, customView: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        let label = makeLabel(text)
        label.widthAnchor.constraint(equalToConstant: 120).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(customView)
        return row
    }

    private func fillValues() {
        apiKeyRow.stringValue = settings.apiKey
        secretKeyRow.stringValue = settings.secretKey
        saveDirField.stringValue = settings.saveDirectory
        hotkeyField.stringValue = hotkeyDisplayString(from: settings.hotkey)
    }

    /// NOTE: 窗口重新打开时刷新最新的设置值，避免显示过期数据
    func updateSettings(_ newSettings: AppSettings) {
        settings = newSettings
        fillValues()
        statusLabel.stringValue = ""
    }

    @objc private func startHotkeyRecording() {
        hotkeyField.beginRecording()
        window?.makeFirstResponder(hotkeyField)
        statusLabel.stringValue = "正在录制热键，按 Esc 取消。"
        statusLabel.textColor = .secondaryLabelColor
    }

    @objc private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: saveDirField.stringValue)
        if panel.runModal() == .OK, let url = panel.url {
            saveDirField.stringValue = url.path
            persistChanges()
        }
    }

    private func schedulePersistChanges() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.persistChanges()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        // NOTE: 防抖 0.5 秒，避免每次按键都触发加密保存和热键重注册
        schedulePersistChanges()
    }

    private func persistChanges() {
        let previousSettings = settings

        settings.apiKey = apiKeyRow.stringValue
        settings.secretKey = secretKeyRow.stringValue
        settings.saveDirectory = saveDirField.stringValue.isEmpty ? defaultSaveDirectory.path : saveDirField.stringValue
        let newHotkey = settings.hotkey.isEmpty ? "control+p" : settings.hotkey
        settings.hotkey = newHotkey

        if HotkeyParser.parse(newHotkey) == nil {
            statusLabel.stringValue = "热键格式无效。"
            statusLabel.textColor = .systemRed
            settings = previousSettings
            hotkeyField.stringValue = hotkeyDisplayString(from: previousSettings.hotkey)
            return
        }

        do {
            if let onSettingsChanged {
                switch onSettingsChanged(settings) {
                case .success:
                    break
                case .failure(let error):
                    settings = previousSettings
                    fillValues()
                    statusLabel.stringValue = "保存失败：\(error)"
                    statusLabel.textColor = .systemRed
                    hotkeyRecordButton.title = "录制"
                    hotkeyRecordButton.isEnabled = true
                    return
                }
            }

            try SecureSettingsStore.shared.save(settings)
            hotkeyField.stringValue = hotkeyDisplayString(from: newHotkey)
            hotkeyRecordButton.title = "录制"
            hotkeyRecordButton.isEnabled = true
            statusLabel.stringValue = "已保存。设置立即生效。"
            statusLabel.textColor = .systemGreen
        } catch {
            settings = previousSettings
            fillValues()
            statusLabel.stringValue = "保存失败：\(error)"
            statusLabel.textColor = .systemRed
        }
    }
}
