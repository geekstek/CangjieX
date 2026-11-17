import AppKit

private final class CandidatePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CandidateBackground: NSStackView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.windowBackgroundColor.setFill(); path.fill()
        NSColor.separatorColor.setStroke(); path.lineWidth = 0.5; path.stroke()
    }
}

private final class CandidateButton: NSButton {
    var selected = false
    var keyLabel = ""
    var candidate = ""
    var fontSize: CGFloat = 17
    var selectionColor = NSColor.controlAccentColor
    private var hovered = false
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if selected || isHighlighted || hovered {
            (selected || isHighlighted ? selectionColor : NSColor.labelColor.withAlphaComponent(0.07)).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let foreground = selected || isHighlighted ? CandidateWindow.selectionTextColor(on: selectionColor) : .labelColor
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let keyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: selected || isHighlighted ? foreground : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let keyHeight = (keyLabel as NSString).size(withAttributes: keyAttributes).height
        (keyLabel as NSString).draw(in: NSRect(x: 6, y: (bounds.height - keyHeight) / 2, width: 20, height: keyHeight),
                                    withAttributes: keyAttributes)
        let textParagraph = NSMutableParagraphStyle(); textParagraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: foreground, .paragraphStyle: textParagraph]
        let height = (candidate as NSString).size(withAttributes: attributes).height
        (candidate as NSString).draw(in: NSRect(x: 34, y: (bounds.height - height) / 2, width: bounds.width - 42, height: height),
                                    withAttributes: attributes)
    }
}

final class CandidateWindow {
    private let panel: NSPanel
    private let stack = CandidateBackground()
    private var choose: ((Int) -> Void)?
    private var turnPage: ((Bool) -> Void)?
    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    init() {
        panel = CandidatePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.title = "倉頡星 候選"
        panel.setAccessibilityLabel("倉頡星 候選")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        panel.contentView = stack
    }

    func hide() {
        panel.orderOut(nil)
        choose = nil
        turnPage = nil
    }

    // Black or white always gives at least 4.5:1 contrast, including custom legacy highlight colors.
    static func selectionTextColor(on background: NSColor) -> NSColor {
        let color = background.usingColorSpace(.sRGB) ?? .black
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
        return luminance > 0.179 ? .black : .white
    }

    func show(_ snapshot: EngineSnapshot, caret: NSRect, windowLevel: Int,
              settings: LegacySettings = LegacySettings(module: [:], loader: [:]), choose: @escaping (Int) -> Void, turnPage: @escaping (Bool) -> Void) {
        guard snapshot.visible, !snapshot.candidates.isEmpty else { hide(); return }
        self.choose = choose
        self.turnPage = turnPage
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        let font = NSFont.systemFont(ofSize: settings.fontSize)
        let textWidth = snapshot.candidates.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 17
        let title = snapshot.correction ? "注音文校正" : "聯想詞"
        let shortcut = "\(snapshot.correction ? "" : "⇧ ")1–\(snapshot.candidates.count)"
        let smallFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let headerWidth = (title as NSString).size(withAttributes: [.font: smallFont]).width
            + (shortcut as NSString).size(withAttributes: [.font: smallFont]).width + 28
        let width = ceil(max(156, snapshot.associated || snapshot.correction ? headerWidth : 0, min(360, textWidth + 42)))
        func sizeView(_ view: NSView, height: CGFloat) {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.heightAnchor.constraint(equalToConstant: height),
                                         view.widthAnchor.constraint(equalToConstant: width)])
        }
        if snapshot.associated || snapshot.correction {
            let header = NSStackView()
            header.orientation = .horizontal
            header.spacing = 8
            header.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
            let label = NSTextField(labelWithString: title)
            label.font = smallFont
            label.textColor = .secondaryLabelColor
            let hint = NSTextField(labelWithString: shortcut)
            hint.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            hint.textColor = .secondaryLabelColor
            hint.setAccessibilityLabel("\(snapshot.correction ? "" : "Shift 加 ")1 到 \(snapshot.candidates.count) 選\(title)")
            for field in [label, hint] {
                field.lineBreakMode = .byClipping
                field.maximumNumberOfLines = 1
                field.setContentCompressionResistancePriority(.required, for: .horizontal)
            }
            header.addArrangedSubview(label)
            header.addArrangedSubview(NSView())
            header.addArrangedSubview(hint)
            sizeView(header, height: 24)
            stack.addArrangedSubview(header)
        }
        let rowHeight = max(28, ceil(settings.fontSize + 8))
        for (index, text) in snapshot.candidates.enumerated() {
            let selected = !snapshot.associated && index == snapshot.highlight
            let button = CandidateButton(title: "", target: self, action: #selector(selectCandidate(_:)))
            button.tag = index
            button.isBordered = false
            button.selected = selected
            button.keyLabel = settings.flags & UInt32(CJX_OPT_SPACE_SELECTS_FIRST) != 0 && !snapshot.associated && !snapshot.correction
                ? (index == 0 ? "␣" : "\(index)") : "\(index + 1)"
            button.candidate = text
            button.fontSize = settings.fontSize
            button.selectionColor = settings.highlight
            button.setAccessibilityLabel("\(snapshot.associated ? "Shift 加 " : "")\(button.keyLabel)，\(text)\(selected ? "，已選取" : "")")
            button.toolTip = "\(text) · \(snapshot.associated ? "⇧ " : "")\(button.keyLabel)"
            sizeView(button, height: rowHeight)
            stack.addArrangedSubview(button)
        }
        let pages = (snapshot.candidateCount + snapshot.perPage - 1) / snapshot.perPage
        if pages > 1 {
            let missingRows = min(snapshot.perPage, snapshot.candidateCount) - snapshot.candidates.count
            if missingRows > 0 {
                let spacer = NSView()
                sizeView(spacer, height: CGFloat(missingRows) * (rowHeight + stack.spacing) - stack.spacing)
                stack.addArrangedSubview(spacer)
            }
            let footer = NSStackView()
            footer.orientation = .horizontal
            footer.spacing = 0
            func pageButton(_ symbol: String, _ action: Selector, _ label: String) -> NSButton {
                let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
                button.isBordered = false
                button.contentTintColor = .secondaryLabelColor
                button.imageScaling = .scaleProportionallyDown
                button.setAccessibilityLabel(label)
                button.toolTip = label
                button.widthAnchor.constraint(equalToConstant: 28).isActive = true
                button.heightAnchor.constraint(equalToConstant: 28).isActive = true
                return button
            }
            let label = NSTextField(labelWithString: "\(snapshot.page + 1) / \(pages)")
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.setAccessibilityLabel("第 \(snapshot.page + 1) 頁，共 \(pages) 頁")
            label.widthAnchor.constraint(equalToConstant: width - 56).isActive = true
            footer.addArrangedSubview(pageButton("chevron.up", #selector(previousPage(_:)), "上一頁候選"))
            footer.addArrangedSubview(label)
            footer.addArrangedSubview(pageButton("chevron.down", #selector(nextPage(_:)), "下一頁候選"))
            sizeView(footer, height: 28)
            stack.addArrangedSubview(footer)
        }
        stack.layoutSubtreeIfNeeded()
        panel.setContentSize(stack.fittingSize)
        stack.layoutSubtreeIfNeeded()
        panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, windowLevel + 1))
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main
        let available = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        panel.setFrame(Self.placement(size: panel.frame.size, caret: caret, visibleFrame: available), display: true)
        panel.orderFrontRegardless()
    }

    static func placement(size: NSSize, caret: NSRect, visibleFrame: NSRect) -> NSRect {
        var origin = NSPoint(x: caret.minX, y: caret.minY - size.height)
        if origin.y < visibleFrame.minY { origin.y = caret.maxY }
        origin.x = min(max(origin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - size.width))
        origin.y = min(max(origin.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - size.height))
        return NSRect(origin: origin, size: size)
    }

    @objc private func selectCandidate(_ sender: NSButton) {
        guard sender.superview === stack else { return }
        choose?(sender.tag)
    }
    @objc private func previousPage(_ sender: NSButton) {
        guard sender.superview?.superview === stack else { return }
        turnPage?(false)
    }
    @objc private func nextPage(_ sender: NSButton) {
        guard sender.superview?.superview === stack else { return }
        turnPage?(true)
    }
}
