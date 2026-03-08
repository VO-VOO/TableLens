import Cocoa

final class ToggleSecureInputRow: NSStackView, NSTextFieldDelegate {
    let secureField = NSSecureTextField(string: "")
    let plainField = NSTextField(string: "")
    let toggleButton = NSButton(title: "", target: nil, action: nil)
    private let accessoryButtonWidth: CGFloat = 72
    private(set) var isRevealed = false
    var onChange: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .horizontal
        spacing = 8

        secureField.isEditable = true
        secureField.isSelectable = true
        plainField.isEditable = true
        plainField.isSelectable = true
        plainField.isHidden = true

        secureField.delegate = self
        plainField.delegate = self

        toggleButton.bezelStyle = .rounded
        toggleButton.controlSize = .large
        toggleButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "显示密钥")
        toggleButton.imagePosition = .imageOnly
        toggleButton.contentTintColor = .labelColor
        toggleButton.target = self
        toggleButton.action = #selector(toggleReveal)
        toggleButton.setButtonType(.momentaryPushIn)
        toggleButton.widthAnchor.constraint(equalToConstant: accessoryButtonWidth).isActive = true

        addArrangedSubview(secureField)
        addArrangedSubview(plainField)
        addArrangedSubview(toggleButton)
    }

    required init?(coder: NSCoder) { nil }

    var stringValue: String {
        get { isRevealed ? plainField.stringValue : secureField.stringValue }
        set {
            secureField.stringValue = newValue
            plainField.stringValue = newValue
        }
    }

    @objc private func toggleReveal() {
        isRevealed.toggle()
        plainField.isHidden = !isRevealed
        secureField.isHidden = isRevealed
        toggleButton.image = NSImage(systemSymbolName: isRevealed ? "eye.slash" : "eye", accessibilityDescription: isRevealed ? "隐藏密钥" : "显示密钥")
        if let window = window {
            window.makeFirstResponder(isRevealed ? plainField : secureField)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        let value = isRevealed ? plainField.stringValue : secureField.stringValue
        secureField.stringValue = value
        plainField.stringValue = value
        onChange?(value)
    }
}
