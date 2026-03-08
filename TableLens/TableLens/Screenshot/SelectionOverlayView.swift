import Cocoa
import Carbon

final class SelectionOverlayView: NSView {
    var onConfirm: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private let image: NSImage
    private var selection: CGRect?
    private var mode: Mode = .idle
    private var dragStart: CGPoint = .zero
    private var originalSelection: CGRect = .zero
    private let accent = NSColor(calibratedRed: 0.62, green: 0.42, blue: 0.98, alpha: 1)
    private let borderColor = NSColor.white.withAlphaComponent(0.92)
    private let handleSize: CGFloat = 10

    enum Mode {
        case idle
        case drawing
        case moving
        case resizing(Handle)
    }

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    init(frame: CGRect, image: NSImage) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        image.draw(in: bounds)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        ctx.fill(bounds)

        if let selection {
            ctx.setBlendMode(.clear)
            ctx.fill(selection)
            ctx.setBlendMode(.normal)
        }
        ctx.restoreGState()

        guard let selection else { return }

        NSColor.white.withAlphaComponent(0.06).setFill()
        selection.fill()

        let shadow = NSShadow()
        shadow.shadowBlurRadius = 24
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()

        borderColor.setStroke()
        let border = NSBezierPath(roundedRect: selection, xRadius: 8, yRadius: 8)
        border.lineWidth = 2
        border.stroke()

        accent.withAlphaComponent(0.65).setStroke()
        let accentBorder = NSBezierPath(roundedRect: selection.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        accentBorder.lineWidth = 1
        accentBorder.stroke()

        NSColor.clear.set()
        NSShadow().set()

        let guides = guideLines(for: selection)
        NSColor.white.withAlphaComponent(0.18).setStroke()
        for guide in guides {
            let path = NSBezierPath()
            path.move(to: guide.0)
            path.line(to: guide.1)
            path.lineWidth = 1
            path.stroke()
        }

        for rect in handleRects(for: selection).values {
            let handlePath = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            accent.setFill()
            handlePath.fill()
            borderColor.setStroke()
            handlePath.lineWidth = 1
            handlePath.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        if let selection, let handle = hitHandle(at: point, in: selection) {
            mode = .resizing(handle)
            originalSelection = selection
        } else if let selection, selection.contains(point) {
            mode = .moving
            originalSelection = selection
        } else {
            mode = .drawing
            selection = CGRect(origin: point, size: .zero)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch mode {
        case .drawing:
            let x = min(dragStart.x, point.x)
            let y = min(dragStart.y, point.y)
            let w = abs(point.x - dragStart.x)
            let h = abs(point.y - dragStart.y)
            selection = CGRect(x: x, y: y, width: w, height: h).standardized
        case .moving:
            let dx = point.x - dragStart.x
            let dy = point.y - dragStart.y
            // NOTE: 用 clamping 替代 intersection，避免拖动到边界时选区被意外缩小
            var moved = originalSelection.offsetBy(dx: dx, dy: dy)
            moved.origin.x = max(0, min(moved.origin.x, bounds.width - moved.width))
            moved.origin.y = max(0, min(moved.origin.y, bounds.height - moved.height))
            selection = moved
        case .resizing(let handle):
            let clampedPoint = CGPoint(
                x: max(0, min(point.x, bounds.width)),
                y: max(0, min(point.y, bounds.height))
            )
            guard var rect = Optional(originalSelection) else { return }
            switch handle {
            case .topLeft:
                rect.origin.x = clampedPoint.x
                rect.origin.y = clampedPoint.y
                rect.size.width = originalSelection.maxX - clampedPoint.x
                rect.size.height = originalSelection.maxY - clampedPoint.y
            case .top:
                rect.origin.y = clampedPoint.y
                rect.size.height = originalSelection.maxY - clampedPoint.y
            case .topRight:
                rect.origin.y = clampedPoint.y
                rect.size.height = originalSelection.maxY - clampedPoint.y
                rect.size.width = clampedPoint.x - originalSelection.minX
            case .right:
                rect.size.width = clampedPoint.x - originalSelection.minX
            case .bottomRight:
                rect.size.width = clampedPoint.x - originalSelection.minX
                rect.size.height = clampedPoint.y - originalSelection.minY
            case .bottom:
                rect.size.height = clampedPoint.y - originalSelection.minY
            case .bottomLeft:
                rect.origin.x = clampedPoint.x
                rect.size.width = originalSelection.maxX - clampedPoint.x
                rect.size.height = clampedPoint.y - originalSelection.minY
            case .left:
                rect.origin.x = clampedPoint.x
                rect.size.width = originalSelection.maxX - clampedPoint.x
            }
            selection = rect.standardized
        case .idle:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mode = .idle
        if let selection, selection.width < 4 || selection.height < 4 {
            self.selection = nil
        }
        needsDisplay = true
    }

    func confirmSelection() {
        guard let selection else { return }
        onConfirm?(selection.standardized)
    }

    func cancelSelection() {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case UInt16(kVK_Return):
            guard let selection else { return }
            onConfirm?(selection.standardized)
        case UInt16(kVK_Escape):
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }


    private func guideLines(for rect: CGRect) -> [(CGPoint, CGPoint)] {
        let thirdsX = [rect.minX + rect.width / 3, rect.minX + rect.width * 2 / 3]
        let thirdsY = [rect.minY + rect.height / 3, rect.minY + rect.height * 2 / 3]
        var lines: [(CGPoint, CGPoint)] = []
        for x in thirdsX {
            lines.append((CGPoint(x: x, y: rect.minY), CGPoint(x: x, y: rect.maxY)))
        }
        for y in thirdsY {
            lines.append((CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y)))
        }
        return lines
    }

    private func handleRects(for rect: CGRect) -> [Handle: CGRect] {
        let midX = rect.midX
        let midY = rect.midY
        let hs = handleSize / 2
        return [
            .topLeft: CGRect(x: rect.minX - hs, y: rect.minY - hs, width: handleSize, height: handleSize),
            .top: CGRect(x: midX - hs, y: rect.minY - hs, width: handleSize, height: handleSize),
            .topRight: CGRect(x: rect.maxX - hs, y: rect.minY - hs, width: handleSize, height: handleSize),
            .right: CGRect(x: rect.maxX - hs, y: midY - hs, width: handleSize, height: handleSize),
            .bottomRight: CGRect(x: rect.maxX - hs, y: rect.maxY - hs, width: handleSize, height: handleSize),
            .bottom: CGRect(x: midX - hs, y: rect.maxY - hs, width: handleSize, height: handleSize),
            .bottomLeft: CGRect(x: rect.minX - hs, y: rect.maxY - hs, width: handleSize, height: handleSize),
            .left: CGRect(x: rect.minX - hs, y: midY - hs, width: handleSize, height: handleSize),
        ]
    }

    private func hitHandle(at point: CGPoint, in rect: CGRect) -> Handle? {
        for (handle, handleRect) in handleRects(for: rect) where handleRect.contains(point) {
            return handle
        }
        return nil
    }
}
