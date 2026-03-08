import Cocoa
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SecureSettingsStore.shared
    private var settings: AppSettings!
    private var statusItem: NSStatusItem!
    private var settingsWindowController: SettingsWindowController?
    private var overlayController: ScreenshotOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        settings = settingsStore.load()
        NotificationHelper.shared.requestAuthorization()
        ensureSaveDirectoryExists()
        setupStatusItem()
        do {
            try applyHotkey()
        } catch {
            showError(String(describing: error))
        }
        checkPermissionsOnLaunch()
        showSettings(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(nil)
        return true
    }

    private func checkPermissionsOnLaunch() {
        Task { @MainActor [weak self] in
            do {
                try await Self.primeScreenCapturePermissionIfNeeded()
            } catch {
                self?.showPermissionAlert(String(describing: error))
            }
        }
    }

    private static func primeScreenCapturePermissionIfNeeded() async throws {
        let shareable = try await SCShareableContent.current
        guard let display = shareable.displays.first else {
            throw AppFailure.message("未检测到可用的屏幕录制权限。请前往“系统设置 → 隐私与安全性 → 屏幕录制”为本 App 授权，然后重启 App。")
        }

        // NOTE: 仅做一次 2x2 的最小抓屏，用来在启动阶段触发系统授权弹窗，
        // 避免用户进入截图层后被弹窗卡住无法点击“允许”。
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.scalesToFit = false
        config.sourceRect = CGRect(x: 0, y: 0, width: 2, height: 2)

        do {
            _ = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw AppFailure.message("当前尚未授予屏幕录制权限。请在系统弹窗中点击“允许”，或前往“系统设置 → 隐私与安全性 → 屏幕录制”为本 App 授权，然后重启 App。")
        }
    }

    private func ensureSaveDirectoryExists() {
        let url = URL(fileURLWithPath: settings.saveDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let iconURL = Bundle.main.url(forResource: "MenuBarIconTemplate", withExtension: "png"),
               let image = NSImage(contentsOf: iconURL) {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                button.image = image
                button.imagePosition = .imageOnly
                button.toolTip = "表格OCR"
            } else {
                button.title = "表格OCR"
            }
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "截图识别", action: #selector(startCapture), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开保存目录", action: #selector(openSaveDirectory), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func applyHotkey(_ hotkey: String? = nil) throws {
        let resolvedHotkey = hotkey ?? settings.hotkey
        let shortcut = HotkeyParser.parse(resolvedHotkey) ?? HotkeyParser.parse("control+p")!
        HotKeyManager.shared.onTrigger = { [weak self] in
            self?.startCapture(nil)
        }
        try HotKeyManager.shared.register(shortcut: shortcut)
    }

    @objc private func startCapture(_ sender: Any?) {
        // NOTE: 快速连续触发截图时，先清理旧的覆盖层和事件监听器
        overlayController?.cancel()
        overlayController = ScreenshotOverlayController()
        overlayController?.begin { [weak self] result in
            switch result {
            case .success(let data):
                OCRService.shared.recognizeTable(imageData: data, settings: self?.settings ?? AppSettings()) { result in
                    switch result {
                    case .success(let excelURL):
                        NotificationHelper.shared.notify(title: "识别成功", body: excelURL.lastPathComponent)
                        NSWorkspace.shared.activateFileViewerSelecting([excelURL])
                    case .failure(let error):
                        NotificationHelper.shared.notify(title: "识别失败", body: String(describing: error))
                        self?.showError(String(describing: error))
                    }
                }
            case .failure(let error):
                NotificationHelper.shared.notify(title: "识别失败", body: String(describing: error))
                self?.showError(String(describing: error))
            }
        }
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            let controller = SettingsWindowController(settings: settings)
            controller.onSettingsChanged = { [weak self] newSettings in
                guard let self else { return .failure(AppFailure.message("应用状态不可用。")) }

                do {
                    if newSettings.hotkey != self.settings.hotkey {
                        try self.applyHotkey(newSettings.hotkey)
                    }
                    self.settings = newSettings
                    self.ensureSaveDirectoryExists()
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            settingsWindowController = controller
        } else {
            // NOTE: 窗口已存在时刷新为最新设置，避免显示过期数据
            settingsWindowController?.updateSettings(settings)
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSaveDirectory(_ sender: Any?) {
        let url = URL(fileURLWithPath: settings.saveDirectory, isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func showPermissionAlert(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = message
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "表格识别失败"
        alert.informativeText = message
        alert.runModal()
    }
}
