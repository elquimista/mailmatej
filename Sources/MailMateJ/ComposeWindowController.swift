import AppKit
import JMAPKit
import MailStore
import MailSync
import QuickLookThumbnailing
import Quartz
import UniformTypeIdentifiers

/// A compose window: From, To, Cc, Bcc, Subject and a plain-text body. Sends through JMAP.
@MainActor
final class ComposeWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSTokenFieldDelegate,
    NSMenuDelegate, NSTextStorageDelegate, NSTextViewDelegate
{
    /// What the window starts with.
    struct Setup {
        var identities: [IdentityRecord]
        var identity: IdentityRecord?
        var draft = Compose.Draft()
        var attachments: [MessagePart] = []
        /// The account the attachments' blobs live in.
        var attachmentsAccountId: String?
        var inReplyTo: [String] = []
        var references: [String] = []
        /// The message replied to or forwarded, and the keyword to set on it once sent.
        var original: (id: Int64, keyword: String)?
    }

    /// Open compose windows; each removes itself when closed.
    private static var open: Set<ComposeWindowController> = []

    private let model: AppModel
    private var setup: Setup
    private let fromPopup = NSPopUpButton()
    private let toField = AddressTokenField()
    private let ccField = AddressTokenField()
    private let bccField = AddressTokenField()
    private let replyToField = AddressTokenField()
    private let subjectField: NSTextField = {
        let field = NSTextField()
        field.cell = LoweredTextFieldCell(textCell: "")
        field.isEditable = true
        field.isBezeled = true
        return field
    }()
    private let textView = ComposeTextView()
    private let attachmentsView = ComposeAttachmentsView()
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var isMarkdown: Bool { formatPopup.indexOfSelectedItem == 0 }
    /// The Content-IDs of pictures embedded in the Markdown (dropped on the text), by file.
    private var contentIDs: [URL: String] = [:]
    /// The format bar's paperclip and total attachment size, shown while there are attachments.
    private let attachedSize = NSTextField(labelWithString: "")
    private let attachedClip = NSImageView()
    /// Files shown in Quick Look.
    private var previewURLs: [URL] = []
    private var rows: [HeaderRow: NSView] = [:]
    private var files: [URL] = []
    private var sending = false
    /// The fields as the window opened, to tell whether the message was edited.
    private var savedState = ""

    /// Header rows the list menu can show or hide (MailMate hides Cc and Bcc until asked).
    private enum HeaderRow: String, CaseIterable {
        case cc = "Cc", bcc = "Bcc", replyTo = "Reply-To"
    }

    static func show(model: AppModel, setup: Setup) {
        model.refreshKnownAddresses(ifOlderThan: 600)
        let controller = ComposeWindowController(model: model, setup: setup)
        open.insert(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.focusFirstField()
    }

    private init(model: AppModel, setup: Setup) {
        self.model = model
        self.setup = setup
        // MailMate's default composer: 878 × 455 pt of content below the toolbar.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 878, height: 456),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        buildToolbar()
        window.setContentSize(NSSize(width: 878, height: 456))  // The toolbar's line covers the top row.
        fill()
        window.setFrameAutosaveName("ComposeWindow")
        cascade(window)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func cascade(_ window: NSWindow) {
        if let last = Self.open.compactMap(\.window).last(where: \.isVisible) {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        } else if !window.setFrameUsingName("ComposeWindow") {
            window.center()
        }
    }

    // MARK: Layout
    //
    // Measured from MailMate at 1x: a 22 pt format bar (under the toolbar line); header labels SF 13 ending at x 65; fields
    // from x 72 to 16 pt from the right edge, 19 pt tall, 8 pt apart; Menlo 11 body with text at x 8;
    // a 45 pt bottom bar with a 17 pt add-attachment button.

    private static let labelEdge: CGFloat = 67
    private static let fieldStart: CGFloat = 72
    /// The square bezel draws 19 pt tall inside a 21 pt frame.
    private static let fieldHeight: CGFloat = 21
    private static let popupWidth: CGFloat = 300  // Draws 301 pt.
    /// AppKit draws token text 4 pt below the token's top, MailMate 2 pt: the token field is laid out 2 pt down and
    /// 18 pt tall (text where MailMate's is), then clipped to MailMate's 15 pt token band.
    private static let tokenInset = (top: CGFloat(2), left: CGFloat(8), height: CGFloat(18), clipTop: CGFloat(4), clipHeight: CGFloat(15), labelBaseline: CGFloat(13))

    private func buildContent() {
        let formatBar = buildFormatBar()
        let header = buildHeader()
        let headerLine = Self.separator()
        let formatLine = Self.separator()

        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont(name: "Menlo-Regular", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 3, height: 7)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        // Spelling is checked and corrected as you type, following the system's text settings, as in MailMate.
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = NSSpellChecker.isAutomaticSpellingCorrectionEnabled
        textView.isAutomaticTextReplacementEnabled = NSSpellChecker.isAutomaticTextReplacementEnabled
        textView.delegate = self
        textView.textStorage?.delegate = self
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // The bottom bar: darker than the window, under a separator: the attachments, or an add button.
        let bottomBar = BottomBar()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        let bottomLine = Self.separator()
        attachmentsView.onAdd = { [weak self] in self?.attachFiles(nil) }
        attachmentsView.onRemove = { [weak self] in self?.removeAttachments($0) }
        attachmentsView.onQuickLook = { [weak self] in self?.quickLookAttachments($0) }
        attachmentsView.onToggleSize = { [weak self] in self?.toggleSizeKind(nil) }
        attachmentsView.onOpen = { [weak self] row in
            self?.withAttachmentFiles([row]) { urls in urls.forEach { NSWorkspace.shared.open($0) } }
        }
        textView.onDropFiles = { [weak self] urls, index in self?.drop(urls, at: index) }

        let content = FileDropView()
        content.onDropFiles = { [weak self] in self?.attach($0) }
        for view in [formatBar, formatLine, header, headerLine, scroll, bottomLine, bottomBar, attachmentsView] {
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            formatBar.topAnchor.constraint(equalTo: content.topAnchor),
            formatBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            formatBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            formatBar.heightAnchor.constraint(equalToConstant: 22),
            formatLine.topAnchor.constraint(equalTo: formatBar.bottomAnchor),
            formatLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            formatLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: formatLine.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            headerLine.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: headerLine.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomLine.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            bottomLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomBar.topAnchor.constraint(equalTo: bottomLine.bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            attachmentsView.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            attachmentsView.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor),
            attachmentsView.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            attachmentsView.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
        ])
        let controller = NSViewController()
        controller.view = content
        window?.contentViewController = controller
    }

    private static func separator() -> NSView {
        let line = SeparatorLine()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    /// The bar under the toolbar: header fields menu | Signature | format.
    private func buildFormatBar() -> NSView {
        let fields = NSPopUpButton(frame: .zero, pullsDown: true)
        fields.isBordered = false
        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "Header Fields")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        fields.menu?.addItem(title)
        for row in HeaderRow.allCases {
            let item = NSMenuItem(title: row.rawValue, action: #selector(toggleHeaderRow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = row.rawValue
            fields.menu?.addItem(item)
        }
        fields.menu?.delegate = self
        fields.toolTip = "Header Fields"
        fields.contentTintColor = .secondaryLabelColor

        let signature = NSPopUpButton(frame: .zero, pullsDown: true)
        signature.addItem(withTitle: "Signature")
        signature.isEnabled = false  // Signatures aren't built yet.

        // MailMate's formats: Markdown (its default: sent as text plus the HTML it makes) or Plain Text.
        formatPopup.addItems(withTitles: ["Markdown", "Plain Text"])
        let format = formatPopup

        for popup in [signature, format] {
            popup.isBordered = false
            popup.font = .systemFont(ofSize: 11)
            (popup.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        }
        let dividers = [FadingDivider(), FadingDivider()]
        let stack = NSStackView(views: [fields, dividers[0], signature, dividers[1], format])
        stack.spacing = 8
        stack.setCustomSpacing(9, after: fields)
        stack.setCustomSpacing(7, after: dividers[0])
        stack.setCustomSpacing(8, after: signature)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 5, bottom: 0, right: 0)
        stack.alignment = .centerY
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        // At the right, as MailMate: a paperclip and the total size in 11 pt regular (fitted to its pixels at
        // 1x), ending 6 pt from the edge.
        attachedClip.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Attachments")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        attachedClip.contentTintColor = .textColor
        attachedSize.font = .systemFont(ofSize: 11)
        attachedSize.textColor = .textColor
        for view in [attachedClip, attachedSize] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggleSizeKind(_:))))
            bar.addSubview(view)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            attachedSize.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -5),
            attachedSize.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            attachedClip.trailingAnchor.constraint(equalTo: attachedSize.leadingAnchor, constant: -3),
            attachedClip.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    private func buildHeader() -> NSView {
        for field in [subjectField] {
            field.font = .systemFont(ofSize: 13)
            field.textColor = .labelColor  // MailMate's field text is label grey, not white.
            field.bezelStyle = .squareBezel
            field.cell?.usesSingleLineMode = true
            field.lineBreakMode = .byTruncatingTail
            field.delegate = self
        }
        for field in [toField, ccField, bccField, replyToField] {
            // Drawn without a bezel inside a separate one (see headerRow), so tokens sit inset as in MailMate.
            field.font = .systemFont(ofSize: 13)
            field.isBezeled = false
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.tokenStyle = .squared
            field.delegate = self
        }
        fromPopup.font = .systemFont(ofSize: 13)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        func add(_ label: String, _ control: NSView, row: HeaderRow? = nil, height: CGFloat? = Self.fieldHeight) {
            let view = headerRow(label, control, height: height)
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if let row { rows[row] = view }
        }
        add("From:", fromPopup, height: nil)
        stack.setCustomSpacing(6, after: stack.arrangedSubviews[0])
        add("To:", toField)
        add("Cc:", ccField, row: .cc)
        add("Bcc:", bccField, row: .bcc)
        add("Reply-To:", replyToField, row: .replyTo)
        add("Subject:", subjectField)
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: header.topAnchor),
            stack.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
        ])
        return header
    }

    /// A label ending at x 65 and its control from x 72 to the right margin, baselines aligned.
    private func headerRow(_ text: String, _ control: NSView, height: CGFloat?) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        var constraints = [label.trailingAnchor.constraint(equalTo: row.leadingAnchor, constant: Self.labelEdge)]
        if let tokens = control as? NSTokenField {
            // MailMate's address fields: 15 pt tokens 8 pt in from the bezel's left edge and 3 pt down from its top,
            // label cap height level with the top of the tokens.
            let bezel = NSTextField()
            bezel.bezelStyle = .squareBezel
            bezel.isEditable = false
            bezel.isSelectable = false
            bezel.refusesFirstResponder = true
            bezel.translatesAutoresizingMaskIntoConstraints = false
            let clip = NSView()
            clip.wantsLayer = true
            clip.layer?.masksToBounds = true
            clip.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(bezel)
            row.addSubview(clip)
            clip.addSubview(tokens)
            (tokens as? AddressTokenField)?.completionAnchor = bezel
            let inset = Self.tokenInset
            NSLayoutConstraint.activate(constraints + [
                bezel.topAnchor.constraint(equalTo: row.topAnchor),
                bezel.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                bezel.heightAnchor.constraint(equalToConstant: Self.fieldHeight),
                bezel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Self.fieldStart),
                bezel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
                clip.topAnchor.constraint(equalTo: bezel.topAnchor, constant: inset.clipTop),
                clip.heightAnchor.constraint(equalToConstant: inset.clipHeight),
                clip.leadingAnchor.constraint(equalTo: bezel.leadingAnchor, constant: inset.left),
                clip.trailingAnchor.constraint(equalTo: bezel.trailingAnchor, constant: -2),
                tokens.topAnchor.constraint(equalTo: clip.topAnchor, constant: inset.top - inset.clipTop),
                tokens.heightAnchor.constraint(equalToConstant: inset.height),
                tokens.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                tokens.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
                label.firstBaselineAnchor.constraint(equalTo: bezel.topAnchor, constant: inset.labelBaseline),
            ])
            return row
        }
        row.addSubview(control)
        constraints += [
            control.topAnchor.constraint(equalTo: row.topAnchor),
            control.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            label.firstBaselineAnchor.constraint(equalTo: control.firstBaselineAnchor),
        ]
        if control === fromPopup {
            // MailMate's pop-up is a fixed width, whatever the identity.
            constraints.append(control.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Self.fieldStart))
            constraints.append(control.widthAnchor.constraint(equalToConstant: Self.popupWidth))
        } else {
            constraints.append(control.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Self.fieldStart))
            constraints.append(control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16))
        }
        if let height { constraints.append(control.heightAnchor.constraint(equalToConstant: height)) }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    private func fill() {
        // "Name <address>", as MailMate lists identities. An account with several addresses gets its name
        // as a heading over them; one with a single address is listed plainly (when there are several accounts).
        let names = Dictionary(uniqueKeysWithValues: ((try? model.store.accounts()) ?? []).map { ($0.id, $0.name) })
        let perAccount = Dictionary(grouping: setup.identities, by: \.accountId)
        let grouped = perAccount.count > 1
        var lastAccount: String?
        for identity in setup.identities {
            let nested = grouped && (perAccount[identity.accountId]?.count ?? 0) > 1
            if nested, identity.accountId != lastAccount {
                fromPopup.menu?.addItem(.sectionHeader(title: names[identity.accountId] ?? ""))
            }
            lastAccount = identity.accountId
            fromPopup.addItem(withTitle: Compose.format(EmailAddress(name: identity.name, email: identity.email)))
            fromPopup.lastItem?.representedObject = identity
            if nested { fromPopup.lastItem?.indentationLevel = 1 }
        }
        if let identity = setup.identity {
            let index = fromPopup.indexOfItem(withRepresentedObject: identity)
            if index >= 0 { fromPopup.selectItem(at: index) }
        }
        toField.addresses = setup.draft.to
        ccField.addresses = setup.draft.cc
        subjectField.stringValue = setup.draft.subject
        textView.string = setup.draft.text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        rows[.cc]?.isHidden = setup.draft.cc.isEmpty
        rows[.bcc]?.isHidden = true
        rows[.replyTo]?.isHidden = true
        updateAttached()
        updateTitle()
        savedState = currentState
    }

    // MARK: Attachments

    /// The forwarded message's attachments, then files added here, in the bottom bar; their total size
    /// in the format bar.
    private func updateAttached() {
        let parts = setup.attachments.map { part in
            ComposeAttachmentsView.Item(
                name: AppModel.fileName(for: part), size: part.size,
                icon: NSWorkspace.shared.icon(for: UTType(mimeType: part.type) ?? .data))
        }
        let added = files.map { url in
            ComposeAttachmentsView.Item(
                name: url.lastPathComponent, size: (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                icon: thumbnails[url] ?? NSWorkspace.shared.icon(forFile: url.path))
        }
        for url in files where thumbnails[url] == nil { makeThumbnail(url) }
        attachmentsView.items = parts + added
        let sizes = attachmentsView.items.compactMap(\.size)
        let encoded = showsEncodedSize
        attachmentsView.showsEncodedSize = encoded
        let total = encoded ? sizes.map(ComposeAttachmentsView.encodedSize).reduce(0, +) : sizes.reduce(0, +)
        attachedSize.stringValue = ComposeAttachmentsView.byteCount(total)
        attachedSize.toolTip = encoded ? "Encoded size" : "File size"
        attachedClip.toolTip = attachedSize.toolTip
        attachedSize.isHidden = attachmentsView.items.isEmpty
        attachedClip.isHidden = attachmentsView.items.isEmpty
    }

    /// Whether this window's attachment sizes (the format bar's total and each row's) are shown once
    /// encoded for sending, as MailMate starts (what a server's size limit counts), rather than as the
    /// files' sizes. A click on any of them switches all of them; every window starts encoded.
    private var showsEncodedSize = true

    @objc private func toggleSizeKind(_ sender: Any?) {
        showsEncodedSize.toggle()
        updateAttached()
    }

    /// Files' Quick Look thumbnails, once made: the picture fitted in 17 × 19 pt with a 1 pt white
    /// border, as MailMate shows images (measured at 1x).
    private var thumbnails: [URL: NSImage] = [:]

    private func makeThumbnail(_ url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 17, height: 19), scale: window?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            guard let picture = thumbnail?.nsImage else { return }
            let image = Self.framed(picture)
            DispatchQueue.main.async {
                guard let self, self.files.contains(url) else { return }
                self.thumbnails[url] = image
                self.updateAttached()
            }
        }
    }

    private nonisolated static func framed(_ picture: NSImage) -> NSImage {
        let fit = min(17 / picture.size.width, 19 / picture.size.height, 1)
        let size = NSSize(width: (picture.size.width * fit).rounded(), height: (picture.size.height * fit).rounded())
        return NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            picture.draw(in: rect.insetBy(dx: 1, dy: 1))
            return true
        }
    }

    /// Adds files (from the open panel or dropped on the window). An empty subject takes the first file's
    /// name, as in MailMate.
    /// Files dropped on the text: in Markdown, pictures are embedded where they're dropped, as MailMate does
    /// (`![](cid:… "name")`, the picture sent inline with that Content-ID); anything else is attached.
    private func drop(_ urls: [URL], at index: Int) {
        guard isMarkdown else { return attach(urls) }
        let pictures = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        attach(urls)
        guard !pictures.isEmpty else { return }
        let domain = (fromPopup.selectedItem?.representedObject as? IdentityRecord)?.email.split(separator: "@").last
            .map(String.init) ?? "mailmatej.local"
        let references = pictures.map { url -> String in
            let cid = contentIDs[url] ?? "\(UUID().uuidString)@\(domain)"
            contentIDs[url] = cid
            let title = url.lastPathComponent.replacingOccurrences(of: "\"", with: "'")
            return "![](cid:\(cid) \"\(title)\")"
        }
        let text = references.joined(separator: "\n\n")
        let location = min(index, (textView.string as NSString).length)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.insertText(text, replacementRange: NSRange(location: location, length: 0))  // undoable, as typing
        window?.makeFirstResponder(textView)
    }

    private func attach(_ urls: [URL]) {
        let new = urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
                && !files.contains(url)
        }
        guard !new.isEmpty else { return }
        files += new
        if subjectField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            subjectField.stringValue = new[0].lastPathComponent
            updateTitle()
        }
        updateAttached()
        updateEdited()
    }

    /// Rows of the bottom bar: the forwarded attachments first, then the files.
    private func removeAttachments(_ rows: IndexSet) {
        let partCount = setup.attachments.count
        setup.attachments = setup.attachments.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        files = files.enumerated().filter { !rows.contains($0.offset + partCount) }.map(\.element)
        updateAttached()
        updateEdited()
    }

    private func quickLookAttachments(_ rows: IndexSet) {
        withAttachmentFiles(rows) { [weak self] urls in
            guard let self, let panel = QLPreviewPanel.shared() else { return }
            previewURLs = urls
            window?.makeFirstResponder(window?.contentView)
            if panel.isVisible { panel.reloadData() } else { panel.makeKeyAndOrderFront(nil) }
        }
    }

    /// The attachments in these rows as files: added files as they are, forwarded ones fetched (usually
    /// from disk) into temporary files.
    private func withAttachmentFiles(_ rows: IndexSet, _ body: @escaping @MainActor ([URL]) -> Void) {
        let parts = setup.attachments, added = files, accountId = setup.attachmentsAccountId
        Task { @MainActor in
            var urls: [URL] = []
            for row in rows {
                if row >= parts.count {
                    urls.append(added[row - parts.count])
                } else if let accountId {
                    // A forwarded attachment: fetched (usually from disk) into a temporary file.
                    let part = parts[row]
                    guard let data = try? await model.partData(accountId: accountId, part: part) else { continue }
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Compose", isDirectory: true)
                        .appendingPathComponent(part.blobId, isDirectory: true)
                    let url = folder.appendingPathComponent(AppModel.fileName(for: part))
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try? data.write(to: url, options: .atomic)
                    urls.append(url)
                }
            }
            if !urls.isEmpty { body(urls) }
        }
    }

    // QuickLookUI declares these outside any actor; AppKit calls them on the main thread.
    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { !previewURLs.isEmpty }
    }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            previewURLs = []
        }
    }

    @objc private func toggleHeaderRow(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let row = HeaderRow(rawValue: name), let view = rows[row]
        else { return }
        view.isHidden.toggle()
        if !view.isHidden { window?.makeFirstResponder(view.subviews.last) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            guard let name = item.representedObject as? String, let row = HeaderRow(rawValue: name) else { continue }
            item.state = rows[row]?.isHidden == false ? .on : .off
        }
    }

    @objc private func attachFiles(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            attach(panel.urls)
        }
    }

    private func focusFirstField() {
        if toField.addresses.isEmpty {
            window?.makeFirstResponder(toField)
        } else {
            window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }

    private func updateTitle() {
        let subject = subjectField.stringValue.trimmingCharacters(in: .whitespaces)
        window?.title = subject.isEmpty ? "New Message" : subject
    }

    /// Address completion, as MailMate's (see AddressCompleter); AppKit's own is off.
    private lazy var completer = AddressCompleter { [weak self] typed, present in
        guard let self else { return [] }
        return Compose.completions(for: typed, in: model.knownAddresses, excluding: present)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let field = control as? AddressTokenField else { return false }
        return completer.handle(commandSelector, in: field)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object is AddressTokenField { completer.close() }
    }

    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? AddressTokenField { completer.textChanged(in: field) }
        if (notification.object as? NSTextField) === subjectField { updateTitle() }
        updateEdited()
    }

    func textDidChange(_ notification: Notification) { updateEdited() }

    // MARK: Quotes

    /// Colours every line starting with ">" as a quote, as MailMate's editor does.
    nonisolated func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        let text = textStorage.string as NSString
        let lines = text.paragraphRange(for: editedRange)
        text.enumerateSubstrings(in: lines, options: [.byParagraphs, .substringNotRequired]) { _, range, enclosing, _ in
            let quoted = range.length > 0 && text.character(at: range.location) == UInt16(UInt8(ascii: ">"))
            textStorage.addAttribute(.foregroundColor, value: quoted ? quoteColor : NSColor.textColor, range: enclosing)
        }
    }

    // MARK: Address tokens

    /// MailMate's tokens start their text 17 pt in; AppKit's 5 pt. En, four-per-em and six-per-em spaces fill the gap.
    private static let tokenLeadIn = "\u{2002}\u{2005}\u{2006}"
    /// And end 3 pt later than AppKit's.
    private static let tokenTail = "\u{2005}"

    func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject representedObject: Any) -> String? {
        // The whole "Name <address>", after the blank lead-in MailMate's tokens have.
        guard let text = representedObject as? String else { return nil }
        return Self.tokenLeadIn + text + Self.tokenTail
    }

    func tokenField(_ tokenField: NSTokenField, editingStringForRepresentedObject representedObject: Any) -> String? {
        representedObject as? String
    }

    func tokenField(_ tokenField: NSTokenField, representedObjectForEditing editingString: String) -> Any? {
        Compose.parseAddresses(editingString).first.map(Compose.format) ?? editingString
    }

    func tokenField(_ tokenField: NSTokenField, hasMenuForRepresentedObject representedObject: Any) -> Bool { true }

    func tokenField(_ tokenField: NSTokenField, menuForRepresentedObject representedObject: Any) -> NSMenu? {
        let menu = NSMenu()
        let address = (representedObject as? String).flatMap { Compose.parseAddresses($0).first }
        if let email = address?.email {
            let header = NSMenuItem(title: email, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }
        let copy = NSMenuItem(title: "Copy Address", action: #selector(copyAddress(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = representedObject
        menu.addItem(copy)
        return menu
    }

    @objc private func copyAddress(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Toolbar

    private static let sendItem = NSToolbarItem.Identifier("send")

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "ComposeToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
        window?.toolbarStyle = .expanded  // Title row above the toolbar, as in MailMate.
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.sendItem] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.sendItem] }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard id == Self.sendItem else { return nil }
        // Same button style as the main window's message buttons.
        let button = NSButton()
        button.bezelStyle = .toolbar
        button.showsBorderOnlyWhileMouseInside = true
        button.image = NSImage(systemSymbolName: "paperplane", accessibilityDescription: "Send")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        button.imagePosition = .imageOnly
        button.toolTip = "Send (⇧⌘D)"
        button.target = self
        button.action = #selector(sendMessage(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        // 40 pt wide puts the glyph where MailMate's is (17 pt from the window edge).
        button.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = button
        item.label = "Send"
        return item
    }

    // MARK: Sending

    @objc func sendMessage(_ sender: Any?) {
        guard !sending, let window else { return }
        guard let identity = fromPopup.selectedItem?.representedObject as? IdentityRecord else {
            return fail("Choose who the message is from.")
        }
        let to = toField.addresses
        let cc = rows[.cc]?.isHidden == false ? ccField.addresses : []
        let bcc = rows[.bcc]?.isHidden == false ? bccField.addresses : []
        let replyTo = rows[.replyTo]?.isHidden == false ? replyToField.addresses : []
        if let bad = (to + cc + bcc + replyTo).first(where: { !Compose.isValid($0) }) {
            return fail("“\(Compose.format(bad))” isn’t a valid email address.")
        }
        guard !(to + cc + bcc).isEmpty else { return fail("Add at least one recipient.") }
        if !setup.attachments.isEmpty, let source = setup.attachmentsAccountId, source != identity.accountId {
            return fail("The forwarded attachments can only be sent from the account the message is in.")
        }
        var message = OutgoingMessage(
            identityId: identity.remoteId, from: EmailAddress(name: identity.name, email: identity.email),
            to: to, cc: cc, bcc: bcc, subject: subjectField.stringValue, text: textView.string,
            attachments: setup.attachments, inReplyTo: setup.inReplyTo, references: setup.references)
        if isMarkdown {
            message.html = MarkdownMail.html(textView.string)
            message.text = MarkdownMail.plainText(textView.string)  // pictures as [ "name" ], as MailMate
        }
        message.replyTo = replyTo
        message.mailFrom = identity.envelopeEmail
        do {
            let shown = isMarkdown ? MarkdownMail.imageContentIDs(textView.string) : []
            message.files = try files.map { url in
                OutgoingFile(
                    name: url.lastPathComponent,
                    type: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                    data: try Data(contentsOf: url),
                    cid: contentIDs[url].flatMap { shown.contains($0) ? $0 : nil })  // still in the text: inline
            }
        } catch {
            return fail("An attached file couldn’t be read.", detail: AppModel.describe(error))
        }

        // As MailMate: the window goes at once and the message is sent in the background; if sending
        // fails, the window comes back with the message as it was and says why.
        sending = true
        window.orderOut(nil)
        Task {
            do {
                try await model.send(message, accountId: identity.accountId, original: setup.original)
                sending = false
                window.close()
                Self.sendFinished(failed: false)
            } catch {
                #if DEBUG
                    NSLog("MMJ compose: send failed: \(AppModel.describe(error))")
                #endif
                sending = false
                window.makeKeyAndOrderFront(nil)
                fail("The message couldn’t be sent.", detail: AppModel.describe(error))
                Self.sendFinished(failed: true)
            }
        }
    }

    /// A quit waiting for messages still being sent (see `confirmQuit`).
    private static var quitAfterSending: ((Bool) -> Void)?

    private static func sendFinished(failed: Bool) {
        guard let reply = quitAfterSending else { return }
        if failed {
            quitAfterSending = nil
            reply(false)  // Stay, so the message that couldn't be sent can be seen.
        } else if !open.contains(where: \.sending) {
            quitAfterSending = nil
            reply(true)
        }
    }

    private func fail(_ message: String, detail: String? = nil) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail ?? ""
        if let window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
    }

    // MARK: Closing

    /// Everything the user can change, including an address still being typed.
    private var currentState: String {
        let addresses = [toField, ccField, bccField, replyToField].map { field in
            "\(field.objectValue ?? "")|\(field.currentEditor()?.string ?? "")"
        }
        return ([subjectField.stringValue, textView.string] + addresses + files.map(\.path)).joined(separator: "\u{1}")
    }

    private var isEdited: Bool { currentState != savedState }

    /// Shows the edited dot in the close button, as MailMate does.
    private func updateEdited() {
        window?.isDocumentEdited = isEdited
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sending { return false }
        guard isEdited else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard this message?"
        alert.informativeText = "It hasn’t been sent, and drafts aren’t saved yet."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.remove(self)
    }

    /// Asked when the app quits: with unsent edited messages open, asks (on the first of them) whether to
    /// discard them, as MailMate does, instead of losing them silently. Calls `reply` with the answer.
    /// Messages still being sent in the background are waited for (the app quits once they're sent).
    static func confirmQuit(_ reply: @escaping (Bool) -> Void) -> Bool {
        let unsent = open.filter { $0.isEdited && !$0.sending }.compactMap(\.window)
        guard let window = unsent.first else {
            guard open.contains(where: \.sending) else { return false }
            quitAfterSending = reply
            return true
        }
        window.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = unsent.count == 1
            ? "Do you want to discard the unsent message?" : "Do you want to discard \(unsent.count) unsent messages?"
        alert.informativeText = "Drafts aren’t saved yet, so quitting loses \(unsent.count == 1 ? "it" : "them")."
        alert.addButton(withTitle: "Discard and Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { reply($0 == .alertFirstButtonReturn) }
        return true
    }

    #if DEBUG
        /// Fills fields as a user would (MMJ_DEBUG_FROM/TO/SUBJECT/BODY) and sends, for scripted tests.
        static func debugSendFrontmost(_ env: [String: String]) {
            guard let c = open.first(where: { $0.window?.isVisible == true }) else {
                return NSLog("MMJ compose: no compose window")
            }
            if let from = env["MMJ_DEBUG_FROM"],
                let identity = c.setup.identities.first(where: { $0.email == from.lowercased() })
            {
                c.fromPopup.selectItem(at: c.fromPopup.indexOfItem(withRepresentedObject: identity))
            }
            if let to = env["MMJ_DEBUG_TO"] { c.toField.addresses = Compose.parseAddresses(to) }
            if let bcc = env["MMJ_DEBUG_BCC"] {
                c.bccField.addresses = Compose.parseAddresses(bcc)
                c.rows[.bcc]?.isHidden = false
            }
            if let paths = env["MMJ_DEBUG_ATTACH"] {  // comma-separated, attached as a drop would
                c.attach(paths.split(separator: ",").map { URL(fileURLWithPath: String($0)) })
            }
            if env["MMJ_DEBUG_TOGGLE_SIZE"] != nil { c.toggleSizeKind(nil) }  // as a click on a size does
            if let row = Int(env["MMJ_DEBUG_SELECT_ATTACHMENT"] ?? "") { c.attachmentsView.debugSelect(row) }
            if let subject = env["MMJ_DEBUG_SUBJECT"] { c.subjectField.stringValue = subject }
            if let body = env["MMJ_DEBUG_BODY"] { c.textView.string = body + c.textView.string }
            if let typed = env["MMJ_DEBUG_TYPE_TO"], let window = c.window {
                // Keys typed into To as a user would; then what the field shows (inline completion selected).
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(c.toField)
                for (i, char) in typed.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(i)) {
                        let (key, code): (String, UInt16) = char == "⇥" ? ("\t", 48) : (String(char), 0)  // ⇥: Tab
                        if let event = NSEvent.keyEvent(
                            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: key,
                            charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)
                        {
                            NSApp.postEvent(event, atStart: false)
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(typed.count) + 1.5) {
                    let editor = c.toField.currentEditor() as? NSTextView
                    if let path = env["MMJ_SNAPSHOT"] {  // the window and the list, captured as the screen shows them
                        for (number, suffix) in [(window.windowNumber, "-compose"), (c.completer.debugPanelNumber ?? 0, "-list")] where number > 0 {
                            let capture = Process()
                            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                            capture.arguments = ["-x", "-o", "-l\(number)", path.replacingOccurrences(of: ".png", with: suffix + ".png")]
                            try? capture.run()
                            capture.waitUntilExit()
                        }
                    }
                    NSLog("MMJ completion: field shows \"\(editor?.string ?? "-")\" selected \(editor.map { NSStringFromRange($0.selectedRange()) } ?? "-"); \(c.completer.debugState); To holds \(c.toField.addresses.map(Compose.format))")
                }
                return
            }
            if let path = env["MMJ_DEBUG_DROP"] {  // a picture dropped at the end of the text
                c.drop([URL(fileURLWithPath: path)], at: (c.textView.string as NSString).length)
            }
            NSLog("MMJ compose: from=\(c.fromPopup.titleOfSelectedItem ?? "-") to=\(c.toField.addresses) cc=\(c.ccField.addresses) subject=\(c.subjectField.stringValue) attachments=\(c.setup.attachments.count) inReplyTo=\(c.setup.inReplyTo) references=\(c.setup.references)\n---\n\(c.textView.string)\n---")
            c.updateTitle()
            c.window?.makeFirstResponder(c.textView)
            if let typed = env["MMJ_DEBUG_TYPE"] {
                c.textView.setSelectedRange(NSRange(location: 0, length: 0))
                c.textView.insertText(typed, replacementRange: c.textView.selectedRange())  // As typing does.
            }
            c.updateEdited()
            NSLog("MMJ compose: edited=\(c.window?.isDocumentEdited ?? false) spellcheck=\(c.textView.isContinuousSpellCheckingEnabled) autocorrect=\(c.textView.isAutomaticSpellingCorrectionEnabled) replacement=\(c.textView.isAutomaticTextReplacementEnabled)")
            if env["MMJ_DEBUG_NOSEND"] == nil {
                c.sendMessage(nil)
                NSLog("MMJ compose: window visible right after Send: \(c.window?.isVisible ?? false)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    NSLog("MMJ compose: 8 s later visible \(c.window?.isVisible ?? false), sheet \(c.window?.attachedSheet != nil), still open \(open.contains(c))")
                }
            }
        }

        static func debugSnapshotFrontmost() -> NSWindow? { open.first(where: { $0.window?.isVisible == true })?.window }
    #endif
}

/// MailMate's colour for quoted lines in the editor: the system blue (on screen it peaks at rgb 0, 154, 255).
private let quoteColor = NSColor.systemBlue

/// An address field: one token per address, kept as "Name <email>" strings.
final class AddressTokenField: NSTokenField {
    /// The view the completion list hangs under (the field's outline).
    weak var completionAnchor: NSView?

    var addresses: [EmailAddress] {
        get {
            ((objectValue as? [Any]) ?? []).compactMap { $0 as? String }.flatMap(Compose.parseAddresses)
        }
        set { objectValue = newValue.map(Compose.format) }
    }
}

/// A 1 pt separator line in the system separator color.
final class SeparatorLine: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}

/// MailMate's divider between format bar items: a vertical line that fades out at both ends.
final class FadingDivider: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 1, height: 18) }

    override func draw(_ dirtyRect: NSRect) {
        // 16 pt tall, 1 pt below the bar's center.
        let color = NSColor.labelColor
        NSGradient(colors: [color.withAlphaComponent(0), color.withAlphaComponent(0.28), color.withAlphaComponent(0)])?
            .draw(in: NSRect(x: 0, y: 0, width: 1, height: 16), angle: 90)
    }
}

/// A text field cell whose text sits 1 pt lower than AppKit's, as in MailMate's Subject field.
final class LoweredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: rect).offsetBy(dx: 0, dy: 1)
    }
}

/// The compose window's bottom bar, a shade darker than the window as in MailMate.
final class BottomBar: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // MailMate's bar is 11 levels darker than the window background.
        NSColor.black.withAlphaComponent(0.2).setFill()
        bounds.fill()
    }
}

extension ComposeWindowController: QLPreviewPanelDataSource {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURLs.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { previewURLs[index] as NSURL }
    }
}
