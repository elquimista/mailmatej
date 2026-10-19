import AppKit
import MailStore

extension Notification.Name {
    static let submailboxSettingsDidChange = Notification.Name("SubmailboxSettingsDidChange")
}

/// MailMate's Submailboxes settings for a unified mailbox (Inbox, Sent Messages, ...): a child in the
/// sidebar for each account's mailbox of that kind.
struct SubmailboxSettings: Codable, Equatable {
    /// "Submailbox for each unique value of Source".
    var bySource = false
    /// "Unless only one submailbox will be created".
    var unlessOnlyOne = true
    /// "Mailbox name format"; empty means the default, `${#source.#name}`.
    var nameFormat = ""
    /// "Submailbox for the messages of each account".
    var byAccount = false

    static let defaultNameFormat = "${#source.#name}"

    private static let defaultsKey = "SubmailboxSettings"

    /// The settings of a unified mailbox (by its sidebar key). As in MailMate, they start split: by
    /// source, except All Messages, by account (by source it would list every folder).
    static func settings(for key: String) -> SubmailboxSettings {
        if let data = UserDefaults.standard.dictionary(forKey: defaultsKey)?[key] as? Data,
            let saved = try? JSONDecoder().decode(SubmailboxSettings.self, from: data)
        {
            return saved
        }
        return key == "unified.all" ? SubmailboxSettings(byAccount: true) : SubmailboxSettings(bySource: true)
    }

    static func save(_ settings: SubmailboxSettings, for key: String) {
        var all = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        all[key] = try? JSONEncoder().encode(settings)
        UserDefaults.standard.set(all, forKey: defaultsKey)
        NotificationCenter.default.post(name: .submailboxSettingsDidChange, object: nil)
    }

    var splits: Bool { bySource || byAccount }

    /// A child's name: the format with `${#source.#name}` as the source's name.
    func name(source: String) -> String {
        let format = nameFormat.trimmingCharacters(in: .whitespaces).isEmpty ? Self.defaultNameFormat : nameFormat
        let name = format.replacingOccurrences(of: Self.defaultNameFormat, with: source)
        return name.isEmpty ? source : name
    }
}

/// The Submailboxes pane of MailMate's mailbox editor, in a window of its own. Laid out at MailMate's
/// positions (measured at 1x): checkboxes 20 pt in, indented rows at 38 pt, 27 pt pitch, a 150 pt Source
/// pop-up, the name format field from 178 pt to 20 pt from the right, a separator, then "each account".
@MainActor
final class SubmailboxSettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let key: String
    private var settings: SubmailboxSettings

    private let bySource = NSButton(checkboxWithTitle: "Submailbox for each unique value of", target: nil, action: nil)
    private let valuePopup = NSPopUpButton()
    private let unlessOne = NSButton(checkboxWithTitle: "Unless only one submailbox will be created", target: nil, action: nil)
    private let formatLabel = NSTextField(labelWithString: "Mailbox name format:")
    private let formatField = NSTextField()
    private let byAccount = NSButton(checkboxWithTitle: "Submailbox for the messages of each account", target: nil, action: nil)

    private static var open: [String: SubmailboxSettingsWindowController] = [:]

    /// Opens (or brings forward) the settings of the unified mailbox `key`, titled `title`.
    static func show(key: String, title: String, over parent: NSWindow?) {
        let controller = open[key] ?? SubmailboxSettingsWindowController(key: key, title: title)
        open[key] = controller
        if let parent, controller.window?.isVisible != true, let window = controller.window {
            let frame = parent.frame
            window.setFrameOrigin(NSPoint(
                x: frame.midX - window.frame.width / 2, y: frame.maxY - window.frame.height - frame.height * 0.2))
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(key: String, title: String) {
        self.key = key
        settings = SubmailboxSettings.settings(for: key)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 150), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = title
        window.subtitle = "Submailboxes"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = buildContent(width: 600)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Self.open[key] = nil }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildContent(width: CGFloat) -> NSView {
        let content = FlippedContentView(frame: NSRect(x: 0, y: 0, width: width, height: 150))
        func place(_ view: NSView, _ frame: NSRect) {
            view.frame = frame
            content.addSubview(view)
        }
        // Rows centered at 28, 55 and 82 pt; separator at 100; last row at 117 (MailMate's pane).
        bySource.sizeToFit()
        place(bySource, NSRect(x: 18, y: 19, width: bySource.frame.width, height: 18))
        valuePopup.addItem(withTitle: "Source")
        valuePopup.controlSize = .regular
        place(valuePopup, NSRect(x: 269, y: 15, width: 154, height: 25))  // Shows 150 pt at 271.
        unlessOne.sizeToFit()
        place(unlessOne, NSRect(x: 36, y: 46, width: unlessOne.frame.width, height: 18))
        formatLabel.sizeToFit()
        place(formatLabel, NSRect(x: 36, y: 74, width: formatLabel.frame.width, height: 17))
        formatField.placeholderString = SubmailboxSettings.defaultNameFormat
        formatField.delegate = self
        place(formatField, NSRect(x: 178, y: 72, width: width - 178 - 20, height: 21))
        let separator = NSBox()
        separator.boxType = .separator
        place(separator, NSRect(x: 20, y: 100, width: width - 40, height: 1))
        byAccount.sizeToFit()
        place(byAccount, NSRect(x: 18, y: 108, width: byAccount.frame.width, height: 18))

        for box in [bySource, unlessOne, byAccount] {
            box.target = self
            box.action = #selector(changed(_:))
        }
        return content
    }

    private func refresh() {
        bySource.state = settings.bySource ? .on : .off
        unlessOne.state = settings.unlessOnlyOne ? .on : .off
        byAccount.state = settings.byAccount ? .on : .off
        formatField.stringValue = settings.nameFormat
        let on = settings.splits
        valuePopup.isEnabled = settings.bySource
        unlessOne.isEnabled = on
        formatLabel.textColor = on ? .labelColor : .disabledControlTextColor
        formatField.isEnabled = on
    }

    @objc private func changed(_ sender: NSButton) {
        settings.bySource = bySource.state == .on
        settings.unlessOnlyOne = unlessOne.state == .on
        settings.byAccount = byAccount.state == .on
        save()
    }

    func controlTextDidChange(_ notification: Notification) {
        settings.nameFormat = formatField.stringValue
        save()
    }

    private func save() {
        SubmailboxSettings.save(settings, for: key)
        refresh()
    }
}

private final class FlippedContentView: NSView {
    override var isFlipped: Bool { true }
}
