import Cocoa
import Carbon

final class HotkeyRecorderField: NSTextField {
    var onRecord: ((String?) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private(set) var isRecordingHotkey = false
    private var keyMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        beginRecording()
    }

    func beginRecording() {
        guard !isRecordingHotkey else { return }
        isRecordingHotkey = true
        stringValue = "请按下新热键"
        onRecordingChanged?(true)
        window?.makeFirstResponder(self)
        installKeyMonitor()
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isRecordingHotkey else { return event }
            return self.handleRecordingEvent(event)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func finishRecording(_ value: String?) {
        isRecordingHotkey = false
        removeKeyMonitor()
        onRecordingChanged?(false)
        onRecord?(value)
        window?.makeFirstResponder(nil)
    }

    private func handleRecordingEvent(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == UInt16(kVK_Escape) {
            finishRecording(nil)
            return nil
        }
        let filtered = event.modifierFlags.intersection([.control, .command, .option, .shift])
        guard !filtered.isEmpty else {
            NSSound.beep()
            onRecord?("__INVALID_NO_MODIFIER__")
            return nil
        }
        guard let hotkey = HotkeyParser.describe(modifiers: filtered, keyCode: event.keyCode, characters: event.charactersIgnoringModifiers) else {
            NSSound.beep()
            return nil
        }
        stringValue = hotkeyDisplayString(from: hotkey)
        finishRecording(hotkey)
        return nil
    }

    override func textShouldBeginEditing(_ textObject: NSText) -> Bool { false }

    deinit {
        removeKeyMonitor()
    }
}
