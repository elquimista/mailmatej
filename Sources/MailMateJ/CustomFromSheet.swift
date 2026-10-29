import AppKit
import JMAPKit
import MailSync

/// MailMate's sheet for Customize… in the From menu (measured at 1x): 452 × 92 pt, the From as
/// "Name <address>" in a field 13 pt in, 426 pt wide, 23 pt down; Cancel and OK (62 pt each, 14 apart)
/// 12 pt from the right and the bottom, OK the default.
@MainActor
final class CustomFromSheet: NSWindowController {
    private let field = NSTextField()
    private var done: (EmailAddress?) -> Void = { _ in }
    private static var shown: CustomFromSheet?

    /// Asks for a From, starting from `value` (selected, to type over). Calls `done` with the address,
    /// or nil for Cancel; OK with something that isn't an address beeps and keeps the sheet.
    static func ask(over window: NSWindow, value: String, done: @escaping (EmailAddress?) -> Void) {
        let sheet = CustomFromSheet()
        sheet.done = done
        sheet.field.stringValue = value
        shown = sheet
        window.beginSheet(sheet.window!) { _ in shown = nil }
        sheet.window?.makeFirstResponder(sheet.field)
        sheet.field.currentEditor()?.selectAll(nil)
    }

    private init() {
        let size = NSSize(width: 452, height: 92)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        let content = panel.contentView!
        let cancel = NSButton(title: "Cancel", target: nil, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "OK", target: nil, action: #selector(ok(_:)))
        ok.keyEquivalent = "\r"
        super.init(window: panel)
        // Bezels as measured, 62 × 20 with their bottoms 13 pt up (a button draws its bezel 1 pt inside
        // its alignment rect either side; the field its own 1 pt inside its frame, its text 27 pt down).
        for (button, x) in [(cancel, 302.0), (ok, 377.0)] {
            button.target = self
            button.frame = button.frame(forAlignmentRect: NSRect(x: x, y: 13, width: 64, height: 20))
            content.addSubview(button)
        }
        field.frame = NSRect(x: 12, y: size.height - 21 - 21, width: 428, height: 21)
        content.addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func finish(ok: Bool) {
        guard let window, let parent = window.sheetParent else { return }
        var address: EmailAddress?
        if ok {
            address = Compose.parseAddresses(field.stringValue).first
            guard let parsed = address, Compose.isValid(parsed) else { return NSSound.beep() }
        }
        parent.endSheet(window)
        done(address)
    }

    @objc private func cancel(_ sender: Any?) { finish(ok: false) }
    @objc private func ok(_ sender: Any?) { finish(ok: true) }

    #if DEBUG
        /// OK with `value` typed (nil: Cancel).
        static func debugFinish(_ value: String?) {
            guard let shown else { return NSLog("MMJ custom from: no sheet") }
            if let value { shown.field.stringValue = value }
            shown.finish(ok: value != nil)
        }
        static var debugValue: String? { shown?.field.stringValue }
    #endif
}
