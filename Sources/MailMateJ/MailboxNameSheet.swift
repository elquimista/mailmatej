import AppKit

/// MailMate's sheet for saving a search (measured at 1x): "Mailbox Name:" 20 pt in, its field to 20 pt
/// from the right, 20 pt down; Cancel, Save and Edit…, Save at the bottom right, Save the default.
@MainActor
final class MailboxNameSheet: NSWindowController, NSTextFieldDelegate {
    private let field = NSTextField()
    private let saveButtons: [NSButton]
    private var done: (String, Bool) -> Void = { _, _ in }
    private static var shown: MailboxNameSheet?

    /// Calls `done` with the name and whether to edit the mailbox; not at all for Cancel.
    static func ask(over window: NSWindow, name: String, done: @escaping (_ name: String, _ edit: Bool) -> Void) {
        let sheet = MailboxNameSheet()
        sheet.done = done
        sheet.field.stringValue = name
        shown = sheet
        window.beginSheet(sheet.window!) { _ in shown = nil }
        sheet.window?.makeFirstResponder(sheet.field)
        sheet.field.currentEditor()?.selectAll(nil)
    }

    private init() {
        let size = NSSize(width: 436, height: 95)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        let content = panel.contentView!
        let label = NSTextField(labelWithString: "Mailbox Name:")
        label.sizeToFit()
        let cancel = NSButton(title: "Cancel", target: nil, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let saveAndEdit = NSButton(title: "Save and Edit\u{2026}", target: nil, action: #selector(saveAndEdit(_:)))
        let save = NSButton(title: "Save", target: nil, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        saveButtons = [saveAndEdit, save]
        super.init(window: panel)
        // Measured on screen: the buttons' bezels end 20 pt from the right, 8 apart, 4 pt above the bottom
        // of the sheet's lower 24 (frames are wider than their bezels).
        var right = size.width - 20 + 9
        for button in [save, saveAndEdit, cancel] {
            button.target = self
            button.sizeToFit()
            button.frame.origin = NSPoint(x: right - button.frame.width, y: 12)
            right -= button.frame.width - 6
            content.addSubview(button)
        }
        field.frame = NSRect(x: 118, y: size.height - 20 - 20, width: size.width - 20 - 118, height: 20)
        field.delegate = self
        label.frame.origin = NSPoint(x: 18, y: size.height - 20 - 21 + (21 - label.frame.height) / 2 + 1)
        content.addSubview(label)
        content.addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// No name, nothing to save.
    func controlTextDidChange(_ obj: Notification) {
        let named = !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        saveButtons.forEach { $0.isEnabled = named }
    }

    private func finish(save: Bool, edit: Bool) {
        guard let window, let parent = window.sheetParent else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        parent.endSheet(window)
        if save, !name.isEmpty { done(name, edit) }
    }

    @objc private func cancel(_ sender: Any?) { finish(save: false, edit: false) }
    @objc private func saveAndEdit(_ sender: Any?) { finish(save: true, edit: true) }
    @objc private func save(_ sender: Any?) { finish(save: true, edit: false) }

    #if DEBUG
        static func debugFinish(name: String?, edit: Bool) {
            guard let shown else { return NSLog("MMJ name sheet: none shown") }
            if let name { shown.field.stringValue = name }
            shown.finish(save: name != nil, edit: edit)
        }
        static var debugIsShown: Bool { shown != nil }
    #endif
}
