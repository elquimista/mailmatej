import AppKit
import JMAPKit
import MailStore

/// "JMAP Account Settings": MailMate's IMAP Account Settings window for a JMAP account. JMAP both
/// receives and sends, so one server section stands in for MailMate's IMAP and SMTP sections.
///
/// Laid out with fixed frames at MailMate's positions (measured at 1x, y from the top of the content):
/// labels right-aligned at 131 pt, fields from 143 pt, 306 pt wide (200 pt beside Port and Require SSL),
/// 28 pt row pitch, a 360 pt separator, the help button bottom left and 82 pt Cancel and Add buttons.
@MainActor
final class AccountSettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let model: AppModel
    private let onClose: () -> Void
    /// The account being edited; nil when adding one.
    let editing: AccountRecord?

    private let descriptionField = NSTextField()
    private let fullNameField = NSTextField()
    private let emailField = NSTextField()
    private let serverField = NSTextField()
    private let portCheckbox = NSButton(checkboxWithTitle: "Port", target: nil, action: nil)
    private let portField = NSTextField()
    private let userField = NSTextField()
    private let sslCheckbox = NSButton(checkboxWithTitle: "Require SSL", target: nil, action: nil)
    private let passwordField = NSSecureTextField()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private var isAdding = false

    init(model: AppModel, editing: AccountRecord? = nil, onClose: @escaping () -> Void) {
        self.model = model
        self.editing = editing
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 260), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "JMAP Account Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        window.initialFirstResponder = descriptionField
        if let editing { fill(from: editing) }
        // The fields are placed by frame, so let the window order Tab by position: row by row, left to right.
        window.autorecalculatesKeyViewLoop = true
        updateAddButton()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(over parent: NSWindow?) {
        if let parent, window?.isVisible != true, let window {
            let frame = parent.frame
            window.setFrameOrigin(NSPoint(
                x: frame.midX - window.frame.width / 2, y: frame.maxY - window.frame.height - frame.height * 0.2))
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose() }

    // MARK: Layout

    private func buildContent() -> NSView {
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 470, height: 260))

        // MailMate's server-section labels end 2 pt further right than the top section's.
        func label(_ text: String, row y: CGFloat, inset: CGFloat = 0) {
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            label.frame = NSRect(x: 0, y: y + 1, width: 133 + inset, height: 17)
            content.addSubview(label)
        }
        func field(_ field: NSTextField, x: CGFloat = 143, y: CGFloat, width: CGFloat) {
            field.frame = NSRect(x: x, y: y, width: width, height: 21)
            field.delegate = self
            field.cell?.isScrollable = true
            field.cell?.wraps = false
            content.addSubview(field)
        }
        func separator(y: CGFloat) {
            let box = NSBox(frame: NSRect(x: 55, y: y, width: 360, height: 1))
            box.boxType = .separator
            content.addSubview(box)
        }

        label("Description:", row: 22)
        field(descriptionField, y: 22, width: 306)
        descriptionField.placeholderString = "Optional"
        label("Full Name:", row: 50)
        field(fullNameField, y: 50, width: 306)
        fullNameField.stringValue = NSFullUserName()
        label("Email Address(es):", row: 78)
        field(emailField, y: 78, width: 306)
        emailField.placeholderString = "you@example.com"

        separator(y: 111)

        label("JMAP Server:", row: 125, inset: 2)
        field(serverField, y: 125, width: 200)
        serverField.placeholderString = "mail.example.com"
        portCheckbox.frame = NSRect(x: 350, y: 126, width: 54, height: 18)
        portCheckbox.target = self
        portCheckbox.action = #selector(portToggled(_:))
        content.addSubview(portCheckbox)
        field(portField, x: 407, y: 125, width: 42)
        portField.isEnabled = false

        label("User Name:", row: 154, inset: 2)
        field(userField, y: 154, width: 200)
        sslCheckbox.frame = NSRect(x: 350, y: 155, width: 100, height: 18)
        sslCheckbox.state = .on
        content.addSubview(sslCheckbox)

        label("Password:", row: 183, inset: 2)
        field(passwordField, y: 183, width: 200)

        let help = NSButton(title: "", target: self, action: #selector(showHelp(_:)))
        help.bezelStyle = .helpButton
        help.frame = NSRect(x: 17, y: 220, width: 25, height: 25)
        content.addSubview(help)

        for (button, x) in [(cancelButton, 271.0), (addButton, 367.0)] {
            button.bezelStyle = .push
            button.frame = NSRect(x: x - 6, y: 216, width: 94, height: 32)
            button.target = self
            content.addSubview(button)
        }
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        addButton.action = #selector(add(_:))
        addButton.keyEquivalent = "\r"

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.frame = NSRect(x: 245, y: 224, width: 16, height: 16)
        content.addSubview(progress)

        return content
    }

    #if DEBUG
        /// Edits the open account as a user would: a new description and, if given, a password; then Save.
        func debugEdit(description: String, password: String, emails: String? = nil) {
            if let emails { emailField.stringValue = emails }
            NSLog("MMJ edit window: server=\(serverField.stringValue) port=\(portCheckbox.state == .on ? portField.stringValue : "-") ssl=\(sslCheckbox.state == .on) user=\(userField.stringValue) desc=\(descriptionField.stringValue) button=\(addButton.title) enabled=\(addButton.isEnabled)")
            descriptionField.stringValue = description
            passwordField.stringValue = password
            updateAddButton()
            add(nil)
        }

        /// Types an email address as a user would, then logs User Name; with `user`, types that user name
        /// first (so the address no longer fills it in).
        func debugTypeEmail(_ email: String, user: String?) {
            if let user {
                userField.stringValue = user
                controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: userField))
            }
            for end in email.indices {
                emailField.stringValue = String(email[...end])
                controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: emailField))
            }
            NSLog("MMJ add account: email \(emailField.stringValue) user \(userField.stringValue) placeholder \(userField.placeholderString ?? "") used \(userName)")
        }

        /// Fills the form as a user would ("server|port|user|password|email"; empty port = none) and adds.
        func debugAdd(_ spec: String) {
            let p = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            descriptionField.stringValue = "Dave (window test)"
            emailField.stringValue = p[4]
            serverField.stringValue = p[0]
            portCheckbox.state = p[1].isEmpty ? .off : .on
            portField.isEnabled = !p[1].isEmpty
            portField.stringValue = p[1]
            sslCheckbox.state = .off
            userField.stringValue = p[2]
            passwordField.stringValue = p[3]
            updateAddButton()
            // Tab order as the window computes it from the first field.
            window?.recalculateKeyViewLoop()
            var order: [String] = []
            var view: NSView? = descriptionField
            for _ in 0..<12 {
                guard let current = view else { break }
                order.append((current as? NSTextField)?.placeholderString ?? (current as? NSButton)?.title ?? "\(type(of: current))")
                view = current.nextValidKeyView
                if view === descriptionField { break }
            }
            NSLog("MMJ account window tab order: \(order)")
            NSLog("MMJ account window: add enabled=\(addButton.isEnabled) url=\(sessionURL?.absoluteString ?? "nil") user=\(userName)")
            add(nil)
        }
    #endif

    /// Shows an account's settings. The password stays empty: it's kept unless one is typed.
    private func fill(from account: AccountRecord) {
        descriptionField.stringValue = account.name
        fullNameField.stringValue = account.fullName
        emailField.stringValue = account.emailAddresses
        if let url = URLComponents(string: account.sessionURL) {
            let path = url.path == "/.well-known/jmap" ? "" : url.path
            serverField.stringValue = (url.host ?? "") + path
            sslCheckbox.state = url.scheme == "http" ? .off : .on
            if let port = url.port {
                portCheckbox.state = .on
                portField.isEnabled = true
                portField.stringValue = String(port)
            }
        }
        userField.stringValue = account.authKind == .basic ? account.username : ""
        updateUserPlaceholder()
        passwordField.placeholderString = "Unchanged"
        addButton.title = "Save"
        updateAddButton()
    }

    // MARK: Actions

    @objc private func portToggled(_ sender: NSButton) {
        portField.isEnabled = sender.state == .on
        if portField.isEnabled { window?.makeFirstResponder(portField) }
        updateAddButton()
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === emailField { updateUserPlaceholder() }
        updateAddButton()
    }

    /// User Name shows the first email address in grey: what's used while it's left empty (see `userName`).
    private func updateUserPlaceholder() {
        userField.placeholderString = emailAddresses.first ?? ""
    }

    private var isFastmail: Bool {
        let server = serverField.stringValue.lowercased()
        return server.contains("fastmail.com")
    }

    private func updateAddButton() {
        let server = !serverField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        let user = isFastmail || !userName.isEmpty
        let port = portCheckbox.state == .off || Int(portField.stringValue).map { (1...65535).contains($0) } == true
        let password = editing != nil || !passwordField.stringValue.isEmpty  // Editing keeps the saved one.
        addButton.isEnabled = server && user && port && password && !isAdding
    }

    /// The user name, or (left empty) the first email address, as servers usually expect it.
    private var userName: String {
        let typed = userField.stringValue.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? emailAddresses.first ?? "" : typed
    }

    private var emailAddresses: [String] { AccountRecord.addresses(in: emailField.stringValue) }

    /// The server's JMAP session URL: Fastmail's fixed one, else the server's `.well-known/jmap`,
    /// with the scheme from Require SSL and the port if one is set.
    private var sessionURL: URL? {
        if isFastmail { return URL(string: "https://api.fastmail.com/jmap/session") }
        let scheme = sslCheckbox.state == .on ? "https" : "http"
        var text = serverField.stringValue.trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        guard var url = JMAPClient.sessionURL(from: scheme + "://" + text),
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        if portCheckbox.state == .on, let port = Int(portField.stringValue) { components.port = port }
        url = components.url ?? url
        return url
    }

    @objc private func add(_ sender: Any?) {
        guard let url = sessionURL else {
            return showError("That doesn’t look like a server address.")
        }
        let draft = AccountDraft(
            name: descriptionField.stringValue.trimmingCharacters(in: .whitespaces), sessionURL: url,
            username: isFastmail ? "" : userName, authKind: isFastmail ? .bearer : .basic,
            secret: passwordField.stringValue.trimmingCharacters(in: isFastmail ? .whitespacesAndNewlines : []),
            fullName: fullNameField.stringValue.trimmingCharacters(in: .whitespaces),
            emailAddresses: AccountRecord.namedAddresses(in: emailField.stringValue).map { entry in
                // Kept as typed: "Name <address>" or the address, so names show in From.
                guard let name = entry.name else { return entry.email }
                let quoted = name.contains(",") || name.contains(";") ? "\"\(name)\"" : name
                return "\(quoted) <\(entry.email)>"
            }.joined(separator: ", "))
        isAdding = true
        progress.startAnimation(nil)
        updateAddButton()
        Task {
            defer {
                isAdding = false
                progress.stopAnimation(nil)
                updateAddButton()
            }
            do {
                let accountId: String
                if let editing {
                    try await model.updateAccount(editing, with: draft)
                    accountId = editing.id
                } else {
                    accountId = try await model.addAccount(draft).id
                }
                // Give listed addresses identities of their own where the server allows; the others are
                // sent through the account's own identity (see MailStore.identities), so a refusal is fine.
                _ = await model.ensureIdentities(accountId: accountId)
                close()
            } catch {
                showError(AppModel.describe(error))
            }
        }
    }

    @objc private func cancel(_ sender: Any?) { close() }

    private func showError(_ text: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = editing == nil ? "Couldn’t add the account." : "Couldn’t save the account."
        alert.informativeText = text
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    @objc private func showHelp(_ sender: NSButton) {
        let text = NSTextField(wrappingLabelWithString: """
            Description is the name shown in the sidebar (optional).
            Full Name is the sender name for your mail, where the server doesn’t set one.
            Email Address(es) are your addresses on this account, comma-separated; the first one is also \
            the user name if you leave User Name empty.

            JMAP Server is the server’s host name, e.g. mail.example.com. For Fastmail, enter fastmail.com \
            and an API token (Settings → Privacy & Security → API tokens) as the password.
            """)
        text.preferredMaxLayoutWidth = 320
        let controller = NSViewController()
        let container = NSView()
        text.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(text)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            text.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            text.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            text.widthAnchor.constraint(equalToConstant: 320),
        ])
        controller.view = container
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }
}

/// A view whose y runs top-down, so frames read like the measurements.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
