import AppKit

/// MailMate's Symbols panel (Symbol ▸ Custom…): the mailbox's symbol drawn large over a combo box of
/// every SF Symbol name, its name selected. A name typed or picked shows in the panel; Apply (or
/// Return) gives it to the mailbox.
/// Measured at 1x: 385 × 228 pt; the symbol's image fitted to 154 pt high (its glyph about 135), centred 84 pt from the top; the
/// field, tip and Apply placed to MailMate's pixels; list rows 18 pt.
@MainActor
final class SymbolPanel: NSPanel, NSComboBoxDataSource, NSComboBoxDelegate {
    private static var shared: SymbolPanel?

    private let preview = NSImageView()
    private let combo = NSComboBox()
    private let tip = NSTextField(labelWithString: "Tip: Use the SF Symbols app to browse symbols")
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private var key = ""

    static func show(key: String, defaultSymbol: String) {
        let panel = shared ?? SymbolPanel()
        shared = panel
        panel.key = key
        let symbol = MailboxSymbols.symbol(for: key) ?? defaultSymbol
        panel.combo.stringValue = MailboxSymbols.drawn.contains(symbol) ? "" : symbol  // drawn here: no SF name to show
        panel.showSymbol(symbol)
        if !panel.isVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.combo)
        panel.combo.currentEditor()?.selectAll(nil)
    }

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 385, height: 228), styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false)
        title = "Symbols"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 385, height: 228))
        contentView = content

        preview.frame = NSRect(x: 10, y: 67, width: 365, height: 154)
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.contentTintColor = .secondaryLabelColor
        content.addSubview(preview)

        combo.frame = NSRect(x: 8, y: 39, width: 371, height: 22)
        combo.usesDataSource = true
        combo.dataSource = self
        combo.delegate = self
        combo.completes = true
        combo.numberOfVisibleItems = 10
        combo.itemHeight = 18
        combo.target = self
        combo.action = #selector(applyClicked(_:))
        content.addSubview(combo)

        tip.font = .systemFont(ofSize: 13)
        tip.textColor = .labelColor
        tip.sizeToFit()
        tip.frame.origin = NSPoint(x: 7, y: 11)
        content.addSubview(tip)

        applyButton.bezelStyle = .push
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(applyClicked(_:))
        applyButton.sizeToFit()
        applyButton.frame.origin = NSPoint(x: 383 - applyButton.frame.width, y: 1)
        content.addSubview(applyButton)
    }

    private func showSymbol(_ name: String) {
        preview.image = MailboxSymbols.image(name, scale: 11, sidebar: false)?
            .withSymbolConfiguration(.init(pointSize: 150, weight: .regular))
    }

    /// Shows the name when it is a symbol (a half-typed one leaves the last one showing).
    private func preview(_ name: String) {
        guard NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else { return }
        showSymbol(name)
    }

    @objc private func applyClicked(_ sender: Any?) {
        let name = combo.stringValue.trimmingCharacters(in: .whitespaces)
        guard NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else { return NSSound.beep() }
        showSymbol(name)
        MailboxSymbols.set(name, for: key)
    }

    func controlTextDidChange(_ obj: Notification) { preview(combo.stringValue) }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        let index = combo.indexOfSelectedItem
        guard MailboxSymbols.allNames.indices.contains(index) else { return }
        let name = MailboxSymbols.allNames[index]
        preview(name)
        // The field shows the plain name, not the list row with its symbol.
        DispatchQueue.main.async { [weak self] in self?.combo.stringValue = name }
    }

    #if DEBUG
        static func debugOpenList() { shared?.combo.cell?.setAccessibilityExpanded(true) }
    #endif

    // MARK: NSComboBoxDataSource

    func numberOfItems(in comboBox: NSComboBox) -> Int { MailboxSymbols.allNames.count }

    /// Each name after its symbol, as MailMate's list shows them.
    func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        let name = MailboxSymbols.allNames[index]
        let row = NSMutableAttributedString()
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        {
            let attachment = NSTextAttachment()
            attachment.image = image
            let size = image.size
            attachment.bounds = NSRect(x: (16 - size.width) / 2, y: -3, width: size.width, height: size.height)
            row.append(NSAttributedString(attachment: attachment))
            row.append(NSAttributedString(string: "\t"))
        }
        row.append(NSAttributedString(string: name))
        return row
    }

    func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
        MailboxSymbols.allNames.first { $0.hasPrefix(string) }
    }

    func comboBox(_ comboBox: NSComboBox, indexOfItemWithStringValue string: String) -> Int {
        MailboxSymbols.allNames.firstIndex(of: string) ?? NSNotFound
    }
}
