import Cocoa
import Carbon
import ScreenCaptureKit

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class ScreenshotOverlayController: NSObject {
    private struct OverlayContext {
        let window: OverlayWindow
        let screen: NSScreen
        let display: SCDisplay
    }

    private var overlays: [OverlayContext] = []
    private var completion: ((Result<Data, Error>) -> Void)?
    private var localKeyMonitor: Any?

    func begin(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion

        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            completion(.failure(AppFailure.message("没有可用屏幕。")))
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let shareable = try await SCShareableContent.current
                let displaysById = Dictionary(uniqueKeysWithValues: shareable.displays.map { ($0.displayID, $0) })
                var captures: [(screen: NSScreen, display: SCDisplay, image: NSImage)] = []

                for screen in screens {
                    guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                        continue
                    }
                    let displayID = CGDirectDisplayID(screenNumber.uint32Value)
                    guard let display = displaysById[displayID] else {
                        continue
                    }
                    let cgImage = try await self.captureDisplayImage(display: display, sourceRect: nil)
                    let image = NSImage(cgImage: cgImage, size: screen.frame.size)
                    captures.append((screen: screen, display: display, image: image))
                }

                guard !captures.isEmpty else {
                    throw AppFailure.message("无法获取当前显示器内容。")
                }

                self.presentOverlays(captures: captures)
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func presentOverlays(captures: [(screen: NSScreen, display: SCDisplay, image: NSImage)]) {
        closeAllOverlays()
        NSApp.activate(ignoringOtherApps: true)

        for (index, capture) in captures.enumerated() {
            let screen = capture.screen
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.acceptsMouseMovedEvents = true
            window.orderFrontRegardless()

            let view = SelectionOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size), image: capture.image)
            view.onCancel = { [weak self] in self?.finish(.failure(AppFailure.message("已取消截图。"))) }
            view.onConfirm = { [weak self, weak window] rect in
                guard let self, let window else { return }
                self.captureSelection(rect: rect, in: window)
            }
            window.contentView = view
            overlays.append(OverlayContext(window: window, screen: screen, display: capture.display))

            if index == 0 {
                window.makeKeyAndOrderFront(nil)
                window.makeMain()
                window.makeFirstResponder(view)
            }
        }

        installLocalKeyMonitor()
    }

    private func installLocalKeyMonitor() {
        removeLocalKeyMonitor()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            guard let view = self.activeSelectionView() else { return event }
            switch event.keyCode {
            case UInt16(kVK_Return):
                view.confirmSelection()
                return nil
            case UInt16(kVK_Escape):
                view.cancelSelection()
                return nil
            default:
                return event
            }
        }
    }

    private func activeSelectionView() -> SelectionOverlayView? {
        if let keyWindow = NSApp.keyWindow as? OverlayWindow,
           let view = keyWindow.contentView as? SelectionOverlayView {
            return view
        }
        return overlays.first?.window.contentView as? SelectionOverlayView
    }

    private func removeLocalKeyMonitor() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private func captureSelection(rect: CGRect, in window: NSWindow) {
        guard let context = overlays.first(where: { $0.window === window }) else {
            finish(.failure(AppFailure.message("显示器上下文丢失。")))
            return
        }

        let localBounds = CGRect(origin: .zero, size: context.screen.frame.size)
        let localRect = rect.standardized.intersection(localBounds)
        guard !localRect.isNull, localRect.width >= 1, localRect.height >= 1 else {
            finish(.failure(AppFailure.message("截图区域无效，请重新选择。")))
            return
        }

        let scaleX = CGFloat(context.display.width) / max(context.screen.frame.width, 1)
        let scaleY = CGFloat(context.display.height) / max(context.screen.frame.height, 1)
        let outputWidth = max(1, Int((localRect.width * scaleX).rounded()))
        let outputHeight = max(1, Int((localRect.height * scaleY).rounded()))
        let sourceRect = localRect

        Task {
            do {
                let cgImage = try await self.captureDisplayImage(
                    display: context.display,
                    sourceRect: sourceRect,
                    outputSize: CGSize(width: outputWidth, height: outputHeight)
                )
                let rep = NSBitmapImageRep(cgImage: cgImage)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    throw AppFailure.message("无法编码截图 PNG 数据。")
                }
                await MainActor.run {
                    self.finish(.success(data))
                }
            } catch {
                await MainActor.run {
                    self.finish(.failure(error))
                }
            }
        }
    }

    private func captureDisplayImage(display: SCDisplay, sourceRect: CGRect?, outputSize: CGSize? = nil) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.scalesToFit = false
        if let sourceRect {
            config.sourceRect = sourceRect
            if let outputSize {
                config.width = max(1, Int(outputSize.width.rounded()))
                config.height = max(1, Int(outputSize.height.rounded()))
            }
        }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private func closeAllOverlays() {
        for overlay in overlays {
            overlay.window.orderOut(nil)
        }
        overlays.removeAll()
    }

    /// NOTE: 截图完成或出错时统一清理资源
    private func finish(_ result: Result<Data, Error>) {
        removeLocalKeyMonitor()
        closeAllOverlays()
        completion?(result)
        completion = nil
    }

    /// NOTE: 外部取消当前截图流程，清理窗口和事件监听器，防止资源泄漏
    func cancel() {
        removeLocalKeyMonitor()
        closeAllOverlays()
        completion = nil
    }
}
