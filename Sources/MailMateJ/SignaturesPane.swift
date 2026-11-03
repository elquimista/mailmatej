import AppKit
import MailStore

/// Settings › Signatures' choices (MailMate's), kept in the app's defaults.
enum SignatureSettings {
    /// Signature based on history: Never, New Messages Only, New Messages and Replies, and New Messages and
    /// Replies (Separately).
    enum History: Int, CaseIterable {
        case never, newOnly, newAndReplies, separately
        var title: String {
            ["Never", "New Messages Only", "New Messages and Replies", "New Messages and Replies (Separately)"][rawValue]
        }
    }

    /// Which messages get a signature by default (none chosen by history).
    enum Default: Int, CaseIterable {
        case none, new, newAndForwards, all
        var title: String { ["None", "New Messages", "New Messages and Forwards", "All Messages"][rawValue] }
    }

    /// Where the text cursor starts in a reply or forward.
    enum Caret: Int, CaseIterable {
        case top, topWithNewlines, aboveSignature
        var title: String { ["Always at Top", "Always at Top (with Newlines)", "Above Signature"][rawValue] }
    }

    static var history: History {
        get { History(rawValue: UserDefaults.standard.object(forKey: "SignatureHistory") as? Int ?? 2) ?? .newAndReplies }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "SignatureHistory") }
    }

    static var defaultFor: Default {
        get { Default(rawValue: UserDefaults.standard.object(forKey: "SignatureDefault") as? Int ?? 3) ?? .all }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "SignatureDefault") }
    }

    /// Default signature placement: above the quoted text (top posting) rather than below it.
    static var top: Bool {
        get { UserDefaults.standard.object(forKey: "SignatureTopPosting") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "SignatureTopPosting") }
    }

    static var caret: Caret {
        get { Caret(rawValue: UserDefaults.standard.object(forKey: "SignatureCaret") as? Int ?? 2) ?? .aboveSignature }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "SignatureCaret") }
    }

    /// Whether typing in a message's signature asks first (off by the warning's "Do not show this warning
    /// again", as MailMate's MmSuppressEditSignatureWarning).
    static var editWarning: Bool {
        get { !UserDefaults.standard.bool(forKey: "SuppressEditSignatureWarning") }
        set { UserDefaults.standard.set(!newValue, forKey: "SuppressEditSignatureWarning") }
    }
}

/// Settings › Signatures, laid out as MailMate's pane (its frames, 622 × 454 pt): the choices on top,
/// then the signatures (Name, Signature, Addresses) with + and −. Double-click one to edit it.
@MainActor
final class SignaturesPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let model: AppModel
    private let table = NSTableView()
    private let removeButton = NSButton()
    private var signatures: [SignatureRecord] = []
    private var editor: SignatureEditor?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        title = "Signatures"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 622, height: 454))
        preferredContentSize = view.frame.size

        func label(_ text: String, _ frame: NSRect) {
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            label.frame = frame
            view.addSubview(label)
        }
        func popup(_ titles: [String], selected: Int, _ frame: NSRect, _ action: Selector) {
            let popup = NSPopUpButton(frame: frame, pullsDown: false)
            popup.addItems(withTitles: titles)
            popup.selectItem(at: selected)
            popup.target = self
            popup.action = action
            view.addSubview(popup)
        }
        label("Signature based on history:", NSRect(x: 48, y: 417, width: 171, height: 17))
        popup(SignatureSettings.History.allCases.map(\.title), selected: SignatureSettings.history.rawValue,
              NSRect(x: 223, y: 411, width: 218, height: 26), #selector(historyChosen(_:)))
        let reset = NSButton(title: "Reset Signature Usage History", target: self, action: #selector(resetHistory(_:)))
        reset.controlSize = .small
        reset.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        reset.frame = NSRect(x: 220, y: 382, width: 187, height: 28)
        view.addSubview(reset)
        label("Default signature:", NSRect(x: 107, y: 362, width: 112, height: 17))
        popup(SignatureSettings.Default.allCases.map(\.title), selected: SignatureSettings.defaultFor.rawValue,
              NSRect(x: 223, y: 356, width: 218, height: 26), #selector(defaultChosen(_:)))
        label("Default signature placement:", NSRect(x: 40, y: 334, width: 179, height: 17))
        for (index, title) in ["Bottom", "Top"].enumerated() {
            let radio = NSButton(radioButtonWithTitle: title, target: self, action: #selector(placementChosen(_:)))
            radio.tag = index
            radio.state = (index == 1) == SignatureSettings.top ? .on : .off
            radio.frame = NSRect(x: 228 + 74 * index, y: 333, width: 70, height: 18)
            view.addSubview(radio)
        }
        label("Caret placement:", NSRect(x: 111, y: 307, width: 108, height: 17))
        popup(SignatureSettings.Caret.allCases.map(\.title), selected: SignatureSettings.caret.rawValue,
              NSRect(x: 223, y: 302, width: 218, height: 26), #selector(caretChosen(_:)))

        for (id, title, width) in [("name", "Name", 114.0), ("signature", "Signature", 196.0), ("addresses", "Addresses", 261.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 40
            table.addTableColumn(column)
        }
        table.style = .plain
        table.rowHeight = 17
        table.intercellSpacing = NSSize(width: 3, height: 2)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editClicked(_:))
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 48, width: 582, height: 243))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        view.addSubview(scroll)

        let add = NSButton(image: NSImage(named: NSImage.addTemplateName)!, target: self, action: #selector(addClicked(_:)))
        removeButton.image = NSImage(named: NSImage.removeTemplateName)
        removeButton.target = self
        removeButton.action = #selector(removeClicked(_:))
        for (button, x) in [(add, 20.0), (removeButton, 42.0)] {
            button.bezelStyle = .smallSquare
            button.frame = NSRect(x: x, y: 19, width: 23, height: 22)
            view.addSubview(button)
        }
        self.view = view
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged(_:)), name: .mailStoreDidChange, object: nil)
    }

    // Servers' signatures change with their accounts' syncs.
    @objc private func storeChanged(_ notification: Notification) { reload() }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    private func reload() {
        let selected = table.selectedRow >= 0 && table.selectedRow < signatures.count ? signatures[table.selectedRow].id : nil
        let fresh = model.signatures()
        guard fresh != signatures else { return updateButtons() }
        signatures = fresh
        table.reloadData()
        if let selected, let row = signatures.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        updateButtons()
    }

    private var selected: SignatureRecord? {
        table.selectedRow >= 0 && table.selectedRow < signatures.count ? signatures[table.selectedRow] : nil
    }

    private func isGmail(_ signature: SignatureRecord) -> Bool {
        signature.server.flatMap { try? model.store.account(id: $0.accountId) }?.isGmail == true
    }

    /// − deletes the selected signature; Gmail's are deleted in Gmail.
    private func updateButtons() {
        removeButton.isEnabled = selected.map { !isGmail($0) } ?? false
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { signatures.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier else { return nil }
        let signature = signatures[row]
        let tip = signature.server.map { isGmail(signature) ? "Kept in Gmail for \($0.email)" : "Kept on the server for \($0.email)" }
        if column.rawValue == "signature" {
            let id = NSUserInterfaceItemIdentifier("cell.signature")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? LinesCellView ?? LinesCellView()
            cell.identifier = id
            // ↩ for each line's end, as MailMate shows them.
            cell.text = signature.text.replacingOccurrences(of: "\n", with: "\u{21A9}")
            cell.toolTip = tip
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("cell." + column.rawValue)
        let field = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = id
            field.lineBreakMode = .byTruncatingTail
            field.cell?.truncatesLastVisibleLine = true
            return field
        }()
        field.stringValue = column.rawValue == "name" ? signature.name : signature.addresses
        field.toolTip = tip
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, removeButton.isEnabled { return removeClicked(nil) }  // ⌫, ⌦
        super.keyDown(with: event)
    }

    // MARK: Actions

    @objc private func historyChosen(_ sender: NSPopUpButton) {
        SignatureSettings.history = .init(rawValue: sender.indexOfSelectedItem) ?? .newAndReplies
    }

    @objc private func defaultChosen(_ sender: NSPopUpButton) {
        SignatureSettings.defaultFor = .init(rawValue: sender.indexOfSelectedItem) ?? .all
    }

    @objc private func caretChosen(_ sender: NSPopUpButton) {
        SignatureSettings.caret = .init(rawValue: sender.indexOfSelectedItem) ?? .aboveSignature
    }

    @objc private func placementChosen(_ sender: NSButton) {
        SignatureSettings.top = sender.tag == 1
    }

    @objc private func resetHistory(_ sender: Any?) {
        try? model.store.resetSignatureUsage()
    }

    @objc private func addClicked(_ sender: Any?) {
        edit(nil)
    }

    @objc private func editClicked(_ sender: Any?) {
        guard table.clickedRow >= 0, table.clickedRow < signatures.count else { return }
        edit(signatures[table.clickedRow])
    }

    @objc private func removeClicked(_ sender: Any?) {
        guard let signature = selected, !isGmail(signature) else { return }
        guard signature.server != nil, let window = view.window else { return model.deleteSignature(signature) }
        // On a server, other apps may use it too: asked first.
        let alert = NSAlert()
        alert.messageText = "Delete the signature of “\(signature.name)” from its server?"
        alert.informativeText = "It’s kept on the server, so it’s deleted there too."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.model.deleteSignature(signature) }
        }
    }

    #if DEBUG
        func debugFillAndSave(_ spec: String) { editor?.debugFillAndSave(spec) }
        /// The rows as the table shows them: name | signature.
        var debugRows: [String] { signatures.map { "\($0.name) | \($0.text.replacingOccurrences(of: "\n", with: "⏎"))" } }
    #endif

    /// Opens the editor as a sheet: for `signature`, or a new one (nil).
    func edit(_ signature: SignatureRecord?) {
        guard let window = view.window, editor == nil else { return }
        var gmail = signature.map(isGmail) ?? false
        #if DEBUG
            if ProcessInfo.processInfo.environment["MMJ_DEBUG_GMAIL_EDITOR"] != nil { gmail = true }  // Dev has no Gmail signatures
        #endif
        let editor = SignatureEditor(model: model, signature: signature, gmail: gmail)
        self.editor = editor
        editor.onDuplicate = { [weak self] copy in
            DispatchQueue.main.async { self?.edit(copy) }
        }
        window.beginSheet(editor.window!) { [weak self] _ in self?.editor = nil }
    }
}

/// The Signature column's text, drawn by a text cell: a label with ↩ in it draws its whole line brighter
/// than its colour (249 against 216, dark), unlike MailMate's table.
private final class LinesCellView: NSTableCellView {
    var text = "" {
        didSet { needsDisplay = true }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let cell = NSTextFieldCell(textCell: text)
        cell.font = .systemFont(ofSize: NSFont.systemFontSize)
        cell.textColor = .labelColor
        cell.lineBreakMode = .byTruncatingTail
        cell.truncatesLastVisibleLine = true
        cell.backgroundStyle = backgroundStyle
        cell.draw(withFrame: bounds, in: self)
    }
}

/// The signature editor (MailMate's, without Theme): Name, Address(es), where it's kept, the signature
/// and its HTML variant. A Gmail signature is shown read-only, with a way to Gmail's settings and to a
/// copy kept here.
@MainActor
final class SignatureEditor: NSWindowController, NSTextFieldDelegate {
    private let model: AppModel
    /// As it was (nil: new). A duplicate starts as a new signature with its fields filled in.
    private let original: SignatureRecord?
    private let start: SignatureRecord
    private let gmail: Bool
    private let nameField = NSTextField()
    private let addressField = NSTextField()
    private let serverCheckbox = NSButton(checkboxWithTitle: "Keep on the server", target: nil, action: nil)
    private let textView = NSTextView()
    private let htmlCheckbox = NSButton(checkboxWithTitle: "HTML Variant:", target: nil, action: nil)
    private let htmlView = NSTextView()
    private let okButton = NSButton(title: "OK", target: nil, action: nil)
    /// The name typed (kept while the server's address stands in for it).
    private var typedName = ""
    /// Called with a copy to edit (a Gmail signature's Duplicate).
    var onDuplicate: ((SignatureRecord) -> Void)?

    init(model: AppModel, signature: SignatureRecord?, gmail: Bool) {
        self.model = model
        self.gmail = gmail
        // A copy (made by Duplicate) has an id no signature has yet: it's new.
        let exists = signature.map { s in model.signatures().contains { $0.id == s.id } } ?? false
        original = exists ? signature : nil
        start = signature ?? SignatureRecord(id: UUID().uuidString, name: "", text: "")
        let window = EditorPanel(
            contentRect: NSRect(x: 0, y: 0, width: 396, height: 327), styleMask: [.titled, .resizable], backing: .buffered,
            defer: false)
        window.minSize = NSSize(width: 396, height: 300)
        super.init(window: window)
        build(in: window.contentView!)
        fill()
        // A Gmail signature's has no Cancel button to take Escape.
        if gmail { window.onEscape = { [weak self] in self?.cancel(nil) } }
    }

    /// The editor's sheet: with `onEscape`, Escape does that, wherever the focus is (a text view would
    /// take it for completion otherwise).
    private final class EditorPanel: NSPanel {
        var onEscape: (() -> Void)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if let onEscape, event.type == .keyDown, event.charactersIgnoringModifiers == "\u{1b}",
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            {
                onEscape()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        override func cancelOperation(_ sender: Any?) {
            if let onEscape { onEscape() } else { super.cancelOperation(sender) }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build(in view: NSView) {
        func label(_ text: String, _ frame: NSRect) {
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            label.frame = frame
            label.autoresizingMask = [.minYMargin]
            view.addSubview(label)
        }
        label("Name:", NSRect(x: 48, y: 287, width: 45, height: 17))
        nameField.frame = NSRect(x: 98, y: 285, width: 278, height: 22)
        label("Address(es):", NSRect(x: 11, y: 255, width: 82, height: 17))
        addressField.frame = NSRect(x: 98, y: 253, width: 278, height: 22)
        addressField.placeholderString = "All"
        addressField.delegate = self
        nameField.delegate = self
        for field in [nameField, addressField] {
            field.autoresizingMask = [.width, .minYMargin]
            view.addSubview(field)
        }
        if gmail {
            let note = NSTextField(labelWithString: "Kept in Gmail.")
            note.frame = NSRect(x: 98, y: 227, width: 120, height: 17)
            note.autoresizingMask = [.minYMargin]
            view.addSubview(note)
            let open = NSButton(title: "Open Gmail Settings", target: self, action: #selector(openGmail(_:)))
            open.controlSize = .small
            open.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            open.sizeToFit()
            open.frame.origin = NSPoint(x: 376 - open.frame.width + 4, y: 223)
            open.autoresizingMask = [.minXMargin, .minYMargin]
            view.addSubview(open)
        } else {
            serverCheckbox.frame = NSRect(x: 96, y: 226, width: 280, height: 18)
            serverCheckbox.target = self
            serverCheckbox.action = #selector(serverToggled(_:))
            serverCheckbox.autoresizingMask = [.minYMargin]
            view.addSubview(serverCheckbox)
        }
        label("Signature:", NSRect(x: 25, y: 195, width: 68, height: 17))

        // The signature above, its HTML variant below, split as MailMate's (78 and 76 pt).
        let split = NSSplitView(frame: NSRect(x: 98, y: 61, width: 278, height: 154))
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]
        let top = NSView(frame: NSRect(x: 0, y: 0, width: 278, height: 78))
        top.addSubview(scrolled(textView, NSRect(x: 0, y: 0, width: 278, height: 78)))
        let bottom = NSView(frame: NSRect(x: 0, y: 0, width: 278, height: 75))
        htmlCheckbox.frame = NSRect(x: -2, y: 50, width: 111, height: 18)
        htmlCheckbox.target = self
        htmlCheckbox.action = #selector(htmlToggled(_:))
        htmlCheckbox.autoresizingMask = [.minYMargin]
        bottom.addSubview(htmlCheckbox)
        bottom.addSubview(scrolled(htmlView, NSRect(x: 0, y: 0, width: 278, height: 45)))
        split.addArrangedSubview(top)
        split.addArrangedSubview(bottom)
        view.addSubview(split)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.frame = NSRect(x: 192, y: 13, width: 96, height: 32)
        cancel.keyEquivalent = "\u{1b}"
        okButton.frame = NSRect(x: 286, y: 13, width: 96, height: 32)
        okButton.target = self
        okButton.action = #selector(ok(_:))
        okButton.keyEquivalent = "\r"
        for button in [cancel, okButton] {
            button.autoresizingMask = [.minXMargin]
            view.addSubview(button)
        }
        if gmail {
            cancel.isHidden = true  // nothing to change
            let duplicate = NSButton(title: "Duplicate", target: self, action: #selector(duplicate(_:)))
            duplicate.frame = NSRect(x: 14, y: 13, width: 96, height: 32)
            duplicate.toolTip = "A copy kept on this Mac, which can be changed"
            view.addSubview(duplicate)
        }
    }

    private func scrolled(_ textView: NSTextView, _ frame: NSRect) -> NSScrollView {
        let scroll = NSScrollView(frame: frame)
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = NSFont(name: "Menlo-Regular", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 2, height: 2)
        scroll.documentView = textView
        return scroll
    }

    private func fill() {
        typedName = start.name
        nameField.stringValue = start.name
        addressField.stringValue = start.addresses
        textView.string = start.text
        htmlCheckbox.state = start.html != nil ? .on : .off
        htmlView.string = start.html ?? ""
        serverCheckbox.state = start.server != nil ? .on : .off
        if gmail {
            for field in [nameField, addressField] { field.isEditable = false }
            for view in [textView, htmlView] { view.isEditable = false }
            htmlCheckbox.isEnabled = false
        }
        update()
    }

    /// The JMAP identity the Address(es) name, if it's exactly one address the server can keep it for:
    /// one that hasn't a server signature already (other than this one).
    private var serverPlace: SignatureRecord.Server? {
        let address = addressField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        guard !address.isEmpty, !address.contains(where: { "*,{} ".contains($0) }),
            let place = try? model.store.jmapIdentity(email: address)
        else { return nil }
        let taken = model.signatures().contains { $0.server == place && $0.id != original?.id }
        return taken ? nil : place
    }

    private func update() {
        guard !gmail else { return }
        let place = serverPlace
        serverCheckbox.isEnabled = place != nil
        if place == nil { serverCheckbox.state = .off }
        serverCheckbox.toolTip = place != nil
            ? "Kept in the account’s identity for \(place!.email), so it’s there on any Mac"
            : "Only for a single address of a JMAP account that has no signature on its server yet"
        // On a server, it's known by its address.
        let onServer = serverCheckbox.state == .on
        nameField.isEnabled = !onServer
        nameField.stringValue = onServer ? place?.email ?? "" : typedName
        htmlView.isEditable = htmlCheckbox.state == .on
        htmlView.textColor = htmlCheckbox.state == .on ? .textColor : .disabledControlTextColor
    }

    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSTextField) === addressField { update() }
        if (notification.object as? NSTextField) === nameField { typedName = nameField.stringValue }
    }

    @objc private func serverToggled(_ sender: Any?) { update() }

    @objc private func htmlToggled(_ sender: Any?) { update() }

    @objc private func openGmail(_ sender: Any?) {
        guard let email = start.server?.email else { return }
        var url = URLComponents(string: "https://mail.google.com/mail/")!
        url.queryItems = [URLQueryItem(name: "authuser", value: email)]
        url.fragment = "settings/general"
        if let url = url.url { NSWorkspace.shared.open(url) }
    }

    @objc private func duplicate(_ sender: Any?) {
        let copy = SignatureRecord(
            id: UUID().uuidString, name: "\(start.name) copy", text: start.text, html: start.html, addresses: start.addresses)
        close(then: { [onDuplicate] in onDuplicate?(copy) })
    }

    @objc private func cancel(_ sender: Any?) { close(then: nil) }

    @objc private func ok(_ sender: Any?) {
        guard !gmail else { return close(then: nil) }
        var signature = SignatureRecord(
            id: start.id, name: nameField.stringValue.trimmingCharacters(in: .whitespaces), text: textView.string,
            html: htmlCheckbox.state == .on ? htmlView.string : nil,
            addresses: addressField.stringValue.trimmingCharacters(in: .whitespaces))
        if serverCheckbox.state == .on, let place = serverPlace {
            signature.server = place
            signature.name = place.email
            signature.addresses = place.email
            // A server's signature is known by its identity, so a moved one gets that id.
            signature.id = "server|\(place.accountId)|\(place.identityId)"
        } else if signature.server == nil, start.server != nil {
            signature.id = UUID().uuidString  // moved here from the server
        }
        if signature.name.isEmpty { signature.name = "Signature" }
        let unchanged = original.map {
            $0.name == signature.name && $0.text == signature.text && $0.html == signature.html
                && $0.addresses == signature.addresses && $0.server == signature.server
        } ?? false
        if !unchanged { model.saveSignature(signature, previous: original) }
        close(then: nil)
    }

    #if DEBUG
        /// Fills the fields ("name|addresses|text|server 0 or 1", empty keeps one) and presses OK.
        func debugFillAndSave(_ spec: String) {
            let p = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if !p[0].isEmpty { nameField.stringValue = p[0]; typedName = p[0] }
            if p.count > 1, !p[1].isEmpty { addressField.stringValue = p[1]; update() }
            if p.count > 2, !p[2].isEmpty { textView.string = p[2].replacingOccurrences(of: "\\n", with: "\n") }
            if p.count > 3, !p[3].isEmpty { serverCheckbox.state = p[3] == "1" ? .on : .off; update() }
            ok(nil)
        }
    #endif

    private func close(then next: (() -> Void)?) {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
        next?()
    }
}
