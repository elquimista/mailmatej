import AppKit
import MailStore
import MailSync
import Quartz
import UniformTypeIdentifiers
import WebKit

/// Shows one message as a single web page: header fields, the remote-content bar and the body,
/// so they scroll together. Scripts never run. Embedded images always show; remote content is
/// blocked unless the user loads it, and trackers/insecure loads never load.
@MainActor
final class MessageViewController: NSViewController, WKNavigationDelegate {
    private let model: AppModel
    private let placeholder = NSTextField(labelWithString: "No Message Selected")
    private var webView: MessageWebView!
    private let partHandler: EmbeddedPartSchemeHandler

    private var currentID: Int64?

    /// The message on screen, if one real message is shown.
    var displayedMessageID: Int64? { currentID.flatMap { $0 > 0 && currentDetail != nil ? $0 : nil } }
    private var currentDetail: MessageDetail?
    private var currentBody: MessageBody?
    /// Files attached to the message on screen, in the order shown.
    private var attachments: [MessagePart] = []
    /// The file Quick Look shows.
    private var previewURL: URL?
    /// Whether the page shows the buttons' ⌥ variants (⌥ is held).
    private var showsOptionVariants = false
    private var flagsMonitor: Any?
    /// The user clicked Load for the message on screen.
    private var loadRemoteForCurrent = false
    /// Identifies this page's action links, so links inside an email can't trigger them.
    private var actionToken = UUID().uuidString

    /// Blocks every network load. Attached unless the user loads remote content.
    private static var blockAllRules: WKContentRuleList?
    /// Blocks trackers and insecure loads. Always attached.
    private static var strictRules: WKContentRuleList?
    /// Blocks every script load. Always attached.
    private static var scriptRules: WKContentRuleList?

    init(model: AppModel) {
        self.model = model
        partHandler = EmbeddedPartSchemeHandler(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let config = WKWebViewConfiguration()
        // Three independent locks on scripts: JavaScript off, `script-src 'none'` in the page CSP,
        // and a content rule blocking script loads.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = true
        config.setURLSchemeHandler(partHandler, forURLScheme: MessageHTML.cidScheme)
        webView = MessageWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsMagnification = true
        webView.onOpen = { [weak self] in self?.openAttachment($0) }
        webView.onButton = { [weak self] index, action, modifiers in
            switch action {
            case "quicklook": self?.quickLookAttachment(index)
            // As MailMate's download button: saves to Downloads; with ⌥, asks where to save.
            case "save" where modifiers.contains(.option): self?.saveAttachment(index)
            case "save": self?.saveAttachmentToDownloads(index)
            default: break
            }
        }
        webView.menuForAttachment = { [weak self] in self?.attachmentMenu($0) }
        webView.dragItem = { [weak self] in self?.draggingItem(forAttachment: $0) }
        // ⌥ changes what the download button does, so its icon and tooltip follow the key.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.showOptionVariants(event.modifierFlags.contains(.option))
            return event
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(appResignedActive), name: NSApplication.didResignActiveNotification, object: nil)
        // Key changes made while something else had the keyboard (another app, the system save panel)
        // never reach us: re-read the key whenever we could have missed one.
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(syncOptionKey), name: name, object: nil)
        }
        webView.onPointerMoved = { [weak self] in self?.syncOptionKey() }

        placeholder.font = .systemFont(ofSize: 15, weight: .medium)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center

        let root = NSView()
        for v in [webView!, placeholder] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
        view = root
        showPlaceholder("No Message Selected")
    }

    func show(messageID: Int64?, selectionCount: Int = 1) {
        guard let messageID else {
            currentID = nil
            showPlaceholder(selectionCount > 1 ? "\(selectionCount) Messages Selected" : "No Message Selected")
            return
        }
        guard messageID != currentID else { return }
        currentID = messageID
        currentBody = nil
        loadRemoteForCurrent = false
        partHandler.allowedMessageID = messageID
        guard let detail = try? model.store.detail(id: messageID) else {
            showPlaceholder("Message Not Found")
            return
        }
        currentDetail = detail
        placeholder.isHidden = true
        webView.isHidden = false

        if let body = try? model.store.body(messageId: messageID) {
            render(body)
            return
        }
        showStatus("Loading…")
        Task {
            do {
                let body = try await model.fetchBody(messageId: messageID, accountId: detail.accountId)
                guard currentID == messageID else { return }
                render(body)
            } catch {
                guard currentID == messageID else { return }
                showStatus("Couldn’t load this message. " + AppModel.describe(error))
            }
        }
    }

    /// Re-renders the current message (e.g. after its data changed).
    func refresh() {
        let id = currentID
        currentID = nil
        show(messageID: id)
    }

    private func showPlaceholder(_ text: String) {
        placeholder.stringValue = text
        placeholder.isHidden = false
        webView.isHidden = true
        currentDetail = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    // MARK: Rendering

    private var currentSender: String? { currentDetail?.addresses(.from).first?.email }

    private var headerFields: [MessagePage.HeaderField] {
        guard let detail = currentDetail else { return [] }
        func list(_ role: AddressRole) -> String {
            detail.addresses(role).map { a in
                // A name that's just the address again is left out, as MailMate does.
                if let name = a.name, !name.isEmpty, name.caseInsensitiveCompare(a.email) != .orderedSame {
                    "\(name) <\(a.email)>"
                } else {
                    a.email
                }
            }.joined(separator: ", ")
        }
        return [
            .init(label: "From:", value: list(.from)),
            .init(label: "Subject:", value: detail.subject, emphasized: true),
            .init(label: "Date:", value: Formatters.fullDate(detail.sentAt ?? detail.receivedAt)),
            .init(label: "To:", value: list(.to)),
            .init(label: "Cc:", value: list(.cc)),
        ]
    }

    private func showStatus(_ text: String) {
        attachments = []
        applyRules(loadRemote: false)
        loadPage(content: "<p class=\"status\">\(MessagePage.escape(text))</p>", bar: nil, plain: false, remote: false)
    }

    private func render(_ body: MessageBody) {
        currentBody = body
        attachments = currentID.map { Self.attachments(messageId: $0, html: body.html, store: model.store) } ?? []
        guard let html = body.html, let id = currentID else {
            applyRules(loadRemote: false)
            loadPage(content: MessagePage.plainHTML(body.text ?? ""), bar: nil, plain: true, remote: false)
            return
        }
        let allowedBy = currentSender.flatMap { try? model.store.remoteContentAllowEntries(email: $0) } ?? []
        // Fail closed: remote content only loads when the strict and script rules are in place.
        let loadRemote = (loadRemoteForCurrent || !allowedBy.isEmpty) && Self.strictRules != nil && Self.scriptRules != nil
        let prepared = MessageHTML.prepare(html, messageId: id, blockRemote: !loadRemote)
        let bar = prepared.remoteCount == 0 ? nil : MessagePage.Bar(
            remote: prepared.remoteCount, strict: prepared.strictCount, loaded: loadRemote,
            canAlwaysLoad: currentSender != nil, allowedBy: allowedBy)
        applyRules(loadRemote: loadRemote)
        loadPage(content: prepared.html, bar: bar, plain: false, remote: loadRemote)
    }

    private func rerender() {
        if let currentBody { render(currentBody) }
    }

    private func loadPage(content: String, bar: MessagePage.Bar?, plain: Bool, remote: Bool) {
        actionToken = UUID().uuidString
        webView.token = actionToken
        webView.resetAttachmentTracking()
        let html = MessagePage.html(
            headers: headerFields, attachments: attachments.map(Self.pageAttachment),
            attachmentButtons: attachments.isEmpty ? [] : Self.attachmentButtons, bar: bar, content: content,
            plain: plain, remote: remote, token: actionToken)
        #if DEBUG
            if let path = ProcessInfo.processInfo.environment["MMJ_DUMP_HTML"] {
                try? html.write(toFile: path, atomically: true, encoding: .utf8)
            }
        #endif
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func applyRules(loadRemote: Bool) {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if let scripts = Self.scriptRules { controller.add(scripts) }
        if let strict = Self.strictRules { controller.add(strict) }
        if !loadRemote, let all = Self.blockAllRules { controller.add(all) }
    }

    /// Compiles the content-rule lists. Call once at launch, before showing messages.
    static func prepareBlockRules() async {
        let store = WKContentRuleListStore.default()
        do {
            blockAllRules = try await store?.compileContentRuleList(
                forIdentifier: "mmj-block-remote",
                encodedContentRuleList: RemoteContentRules.contentRuleListJSON(RemoteContentRules.remotePatterns))
            strictRules = try await store?.compileContentRuleList(
                forIdentifier: "mmj-block-strict",
                encodedContentRuleList: RemoteContentRules.contentRuleListJSON(RemoteContentRules.strictPatterns))
            scriptRules = try await store?.compileContentRuleList(
                forIdentifier: "mmj-block-scripts",
                encodedContentRuleList: #"[{"trigger":{"url-filter":".*","resource-type":["script"]},"action":{"type":"block"}}]"#)
        } catch {
            NSLog("MailMateJ: could not compile remote-content rules: \(error)")
        }
    }

    // MARK: Attachments

    /// The message's attachments: its saved parts, except images the body shows inline.
    static func attachments(messageId: Int64, html: String?, store: MailStore) -> [MessagePart] {
        let body = html?.lowercased() ?? ""
        return ((try? store.parts(messageId: messageId)) ?? []).filter { part in
            guard let cid = part.cid else { return true }
            return !body.contains("cid:" + cid)
        }
    }

    private static var iconCache: [String: String] = [:]

    static func pageAttachment(_ part: MessagePart) -> MessagePage.Attachment {
        let name = AppModel.fileName(for: part)
        let size = part.size.map(Self.binarySize) ?? ""
        return MessagePage.Attachment(name: name, size: size, icon: iconDataURL(forFileNamed: name, type: part.type))
    }

    /// "51 B", "4.2 KiB", "32.6 KiB": binary units, as MailMate shows attachment sizes.
    static func binarySize(_ bytes: Int) -> String {
        guard bytes >= 1024 else { return "\(bytes) B" }
        var value = Double(bytes) / 1024
        for unit in ["KiB", "MiB", "GiB"] {
            if value < 1024 || unit == "GiB" {
                return String(format: "%.1f %@", value, unit)  // "32.6 KiB", one decimal as MailMate shows
            }
            value /= 1024
        }
        return "\(bytes) B"
    }

    /// The rows' round buttons, drawn as MailMate draws them (measured at 1x): 20 px grey circles showing
    /// as (171, 172, 172), with the symbol cut out. Drawn in 157, which WebKit shows as 171 here.
    private static let attachmentButtons: [MessagePage.AttachmentButton] = [
        .init(action: "quicklook", title: "Quick Look", icon: circleButtonDataURL("eye.circle.fill")),
        .init(
            action: "save", title: "Save to Downloads", icon: circleButtonDataURL("arrow.down.circle.fill"),
            optionTitle: "Save As…", optionIcon: circleButtonDataURL("folder.circle.fill")),
    ]

    private static func circleButtonDataURL(_ symbolName: String) -> String {
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 32, weight: .regular))
        else { return "" }
        // The circle's ink, scaled to exactly 40 × 40 pixels (20 pt on Retina).
        let ink = MessageListViewController.inkBounds(of: symbol, integral: false)
        let side = 40
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return "" }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let scale = CGFloat(side) / max(ink.width, ink.height)
        symbol.draw(
            in: NSRect(x: -ink.minX * scale, y: -ink.minY * scale, width: symbol.size.width * scale, height: symbol.size.height * scale))
        NSColor(srgbRed: 157 / 255, green: 157 / 255, blue: 157 / 255, alpha: 1).set()
        NSRect(x: 0, y: 0, width: side, height: side).fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]).map { "data:image/png;base64," + $0.base64EncodedString() } ?? ""
    }

    /// The file type's Finder icon as a 40 px PNG (sharp at 20 pt on Retina), cached per type.
    private static func iconDataURL(forFileNamed name: String, type: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        let key = ext.isEmpty ? type : ext
        if let cached = iconCache[key] { return cached }
        let utType = UTType(filenameExtension: ext) ?? UTType(mimeType: type) ?? .data
        let icon = NSWorkspace.shared.icon(for: utType)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        var url = ""
        if let rep {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            icon.draw(in: NSRect(x: 0, y: 0, width: 40, height: 40))
            NSGraphicsContext.restoreGraphicsState()
            if let png = rep.representation(using: .png, properties: [:]) {
                url = "data:image/png;base64," + png.base64EncodedString()
            }
        }
        iconCache[key] = url
        return url
    }

    /// Runs `body` with the attachment as a file, or reports why it couldn't be fetched.
    private func withAttachmentFile(_ index: Int, _ body: @escaping @MainActor (URL) -> Void) {
        guard attachments.indices.contains(index), let id = currentID, let detail = currentDetail else { return }
        let part = attachments[index]
        Task { @MainActor in
            do {
                let url = try await model.attachmentFile(messageId: id, index: index, accountId: detail.accountId, part: part)
                body(url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t get “\(AppModel.fileName(for: part))”."
                alert.informativeText = AppModel.describe(error)
                if let window = view.window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            }
        }
    }

    private func openAttachment(_ index: Int) {
        withAttachmentFile(index) { NSWorkspace.shared.open($0) }
    }

    private func quickLookAttachment(_ index: Int) {
        withAttachmentFile(index) { [weak self] url in
            guard let self, let panel = QLPreviewPanel.shared() else { return }
            previewURL = url
            view.window?.makeFirstResponder(webView)
            if panel.isVisible { panel.reloadData() } else { panel.makeKeyAndOrderFront(nil) }
        }
    }

    private func saveAttachment(_ index: Int) {
        guard attachments.indices.contains(index), let window = view.window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AppModel.fileName(for: attachments[index])
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.syncOptionKey()  // ⌥ may have been released while the panel had the keyboard.
            guard response == .OK, let target = panel.url else { return }
            self?.withAttachmentFile(index) { source in self?.copy(source, to: target, replacing: true) }
        }
    }

    /// Saves into ~/Downloads without asking, as MailMate's download button does, and bounces the
    /// Downloads stack in the Dock as browsers do.
    private func saveAttachmentToDownloads(_ index: Int) {
        withAttachmentFile(index) { [weak self] source in
            guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
            let target = Self.unusedURL(downloads.appendingPathComponent(source.lastPathComponent))
            if self?.copy(source, to: target, replacing: false) == true {
                DistributedNotificationCenter.default().post(
                    name: Notification.Name("com.apple.DownloadFileFinished"), object: target.path)
            }
        }
    }

    /// "name.ext", then "name 2.ext", "name 3.ext", … whichever doesn't exist yet.
    private static func unusedURL(_ url: URL) -> URL {
        let folder = url.deletingLastPathComponent(), ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var candidate = url, n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    @discardableResult
    private func copy(_ source: URL, to target: URL, replacing: Bool) -> Bool {
        do {
            if replacing && FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: Self.stagedCopy(of: source))
            } else {
                try FileManager.default.copyItem(at: source, to: target)
            }
            try AppModel.quarantine(target)
            return true
        } catch {
            let alert = NSAlert(error: error)
            if let window = view.window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            return false
        }
    }

    /// A copy of `source` beside it, for replacing a file in one step.
    private static func stagedCopy(of source: URL) throws -> URL {
        let staged = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: staged)
        return staged
    }

    private func attachmentMenu(_ index: Int) -> NSMenu? {
        guard attachments.indices.contains(index) else { return nil }
        let menu = NSMenu()
        for (title, action) in [
            ("Open Attachment", #selector(openAttachmentItem(_:))),
            ("Quick Look", #selector(quickLookAttachmentItem(_:))),
            ("Save Attachment…", #selector(saveAttachmentItem(_:))),
            ("Save to Downloads", #selector(saveAttachmentToDownloadsItem(_:))),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
            if action == #selector(quickLookAttachmentItem(_:)) { menu.addItem(.separator()) }
        }
        return menu
    }

    @objc private func openAttachmentItem(_ sender: NSMenuItem) { openAttachment(sender.tag) }
    @objc private func quickLookAttachmentItem(_ sender: NSMenuItem) { quickLookAttachment(sender.tag) }
    @objc private func saveAttachmentItem(_ sender: NSMenuItem) { saveAttachment(sender.tag) }
    @objc private func saveAttachmentToDownloadsItem(_ sender: NSMenuItem) { saveAttachmentToDownloads(sender.tag) }

    /// A file promise, so the file is fetched (if it isn't cached yet) only once it's dropped somewhere.
    private func draggingItem(forAttachment index: Int) -> NSDraggingItem? {
        guard attachments.indices.contains(index), let id = currentID, let detail = currentDetail else { return nil }
        let part = attachments[index]
        let name = AppModel.fileName(for: part)
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? UTType(mimeType: part.type) ?? .data
        let promise = AttachmentPromise(
            fileType: type.identifier,
            delegate: AttachmentPromiseDelegate(model: model, messageId: id, index: index, accountId: detail.accountId, part: part))
        let item = NSDraggingItem(pasteboardWriter: promise)
        let icon = NSWorkspace.shared.icon(for: type)
        let location = webView.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        item.setDraggingFrame(NSRect(x: location.x - 16, y: location.y - 16, width: 32, height: 32), contents: icon)
        return item
    }

    private func showOptionVariants(_ on: Bool, force: Bool = false) {
        guard on != showsOptionVariants || force, !attachments.isEmpty || !on else {
            showsOptionVariants = on
            return
        }
        showsOptionVariants = on
        webView.callAsyncJavaScript(
            MessagePage.optionKeyScript, arguments: ["option": on], in: nil, in: .defaultClient, completionHandler: nil)
    }

    /// Keys released while another app is in front never reach us.
    @objc private func appResignedActive() { showOptionVariants(false) }

    @objc private func syncOptionKey() { showOptionVariants(NSEvent.modifierFlags.contains(.option)) }

    // MARK: Quick Look

    // QuickLookUI declares these outside any actor; AppKit calls them on the main thread.
    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { previewURL != nil }
    }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            previewURL = nil
        }
    }

    // MARK: Remote-content actions

    private func perform(_ action: MessagePage.Action) {
        switch action {
        case .load:
            loadRemoteForCurrent = true
            rerender()
        case .alwaysLoadMenu:
            showAlwaysLoadMenu()
        case .stopAlwaysLoading:
            guard let sender = currentSender else { return }
            for entry in (try? model.store.remoteContentAllowEntries(email: sender)) ?? [] {
                try? model.store.disallowRemoteContent(entry)
            }
            loadRemoteForCurrent = false
            rerender()
        }
    }

    private func showAlwaysLoadMenu() {
        guard let sender = currentSender, let window = view.window else { return }
        let menu = NSMenu()
        menu.addItem(alwaysLoadItem(title: sender, value: sender))
        if let domain = sender.split(separator: "@").last {
            menu.addItem(alwaysLoadItem(title: "Anyone at \(domain)", value: "@\(domain)"))
        }
        let point = webView.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        menu.popUp(positioning: nil, at: point, in: webView)
    }

    private func alwaysLoadItem(title: String, value: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(alwaysLoadChosen(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = value
        return item
    }

    @objc private func alwaysLoadChosen(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        try? model.store.allowRemoteContent(value)
        rerender()
    }

    #if DEBUG
        func debugLoadRemote() { perform(.load) }

        /// Logs what the app-world hit test finds at each attachment item's center, then fetches the
        /// first attachment to a file (without opening it) and logs its path and quarantine flag.
        func debugCheckAttachments() async {
            NSLog("MMJ attachments: \(attachments.map { AppModel.fileName(for: $0) })")
            try? await Task.sleep(for: .seconds(1))  // Let the page finish loading.
            func run(_ script: String) async -> String {
                await withCheckedContinuation { done in
                    webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { result in
                        done.resume(returning: String(describing: result))
                    }
                }
            }
            let probe = await run(
                "return document.querySelectorAll('mmj-att').length + ' items, page scripts ' + "
                    + "(document.querySelector('noscript') ? 'n/a' : 'off')")
            NSLog("MMJ attachment probe: \(probe)")
            NSLog("MMJ chrome style: \(await run("const c = getComputedStyle(document.querySelector('mmj-chrome')); return c.backgroundColor + ' ' + c.opacity + ' scheme ' + matchMedia('(prefers-color-scheme: dark)').matches"))")
            let centers = await run(
                "return [...document.querySelectorAll('mmj-att')].map(e => { const r = e.getBoundingClientRect(); "
                    + "const hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2); "
                    + "const item = hit && hit.closest('mmj-attachments mmj-att'); "
                    + "return item ? item.getAttribute('data-mmj-att') : 'miss'; }).join(' ')")
            NSLog("MMJ attachment hit test: \(centers) token=\(actionToken)")

            // Hover detection as the pointer would drive it: a synthetic move over the second item.
            let rect = await run(
                "const r = document.querySelectorAll('mmj-att')[1].querySelector('mmj-btn').getBoundingClientRect(); "
                    + "return (r.x + r.width / 2) + ',' + (r.y + r.height / 2)")
            let numbers = rect.replacingOccurrences(of: "success(", with: "").replacingOccurrences(of: ")", with: "")
                .split(separator: ",").compactMap { Double($0) }
            if numbers.count == 2, let window = view.window {
                let inView = NSPoint(x: numbers[0], y: webView.isFlipped ? numbers[1] : webView.bounds.height - numbers[1])
                let inWindow = webView.convert(inView, to: nil)
                if let move = NSEvent.mouseEvent(
                    with: .mouseMoved, location: inWindow, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
                {
                    webView.mouseMoved(with: move)
                    try? await Task.sleep(for: .milliseconds(500))
                    NSLog("MMJ attachment hovered after move: \(String(describing: webView.hoveredAttachment)) button=\(String(describing: webView.hoveredButton))")
                    NSLog("MMJ attachment menu: \(attachmentMenu(1)?.items.map(\.title) ?? [])")
                }
            }
            if ProcessInfo.processInfo.environment["MMJ_DEBUG_OPTION"] != nil {
                showOptionVariants(true)
                try? await Task.sleep(for: .milliseconds(300))
                let state = await run(
                    "const b = document.querySelector('mmj-btn[data-mmj-btn=save]'); "
                        + "return b.title + ' | visible: ' + [...b.querySelectorAll('img')].map(i => getComputedStyle(i).display).join(',')")
                NSLog("MMJ attachment option state: \(state)")
                syncOptionKey()  // As after the save panel closes, with ⌥ not held.
                try? await Task.sleep(for: .milliseconds(300))
                let after = await run(
                    "const b = document.querySelector('mmj-btn[data-mmj-btn=save]'); "
                        + "return b.title + ' | visible: ' + [...b.querySelectorAll('img')].map(i => getComputedStyle(i).display).join(',')")
                NSLog("MMJ attachment option state after sync: \(after)")
            }
            if ProcessInfo.processInfo.environment["MMJ_DEBUG_QUICKLOOK"] != nil {
                quickLookAttachment(1)
                try? await Task.sleep(for: .seconds(2))
                NSLog("MMJ attachment Quick Look visible: \(QLPreviewPanel.shared()?.isVisible ?? false) item=\(previewURL?.lastPathComponent ?? "none")")
            }
            withAttachmentFile(0) { url in
                let q = (try? url.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties
                NSLog("MMJ attachment file: \(url.path) size=\((try? Data(contentsOf: url))?.count ?? -1) quarantine=\(q != nil)")
            }
        }

        /// Shows arbitrary HTML through the normal pipeline (prepare, page, content rules).
        func debugRender(html: String) {
            currentID = -1  // Keeps the selected message's header, if any.
            partHandler.allowedMessageID = -1
            placeholder.isHidden = true
            webView.isHidden = false
            render(MessageBody(html: html, text: nil))
        }

        /// Writes the web view's content at full (Retina) resolution.
        func debugSnapshotWeb(to path: String) async {
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = NSNumber(value: Double(webView.bounds.width * 2))  // 2x pixels
            guard let image = try? await webView.takeSnapshot(configuration: config),
                let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return }
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }

        /// Scrolls the message content, as the scroll wheel would.
        func debugScrollContent(by points: CGFloat) {
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-points), wheel2: 0, wheel3: 0),
                let nsEvent = NSEvent(cgEvent: event)
            else { return }
            webView.scrollWheel(with: nsEvent)
        }
    #endif

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A new page starts with the plain buttons; match the key if it's held right now.
        showsOptionVariants = false
        if NSEvent.modifierFlags.contains(.option) && !attachments.isEmpty { showOptionVariants(true, force: true) }
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        if navigationAction.navigationType == .linkActivated {
            if let action = MessagePage.action(from: url, token: actionToken) {
                perform(action)
            } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                // Clicked links open in the browser (only web and mail links).
                NSWorkspace.shared.open(url)
            }
            return decisionHandler(.cancel)
        }
        // The view only ever shows the page we load (about:blank). Anything else, such as a meta refresh
        // to a remote page where our CSP would no longer apply, is refused.
        decisionHandler(url.scheme == "about" ? .allow : .cancel)
    }
}

extension MessageViewController: QLPreviewPanelDataSource {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURL == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { previewURL as NSURL? }
    }
}

/// Keeps its delegate alive for the length of the drag (the provider holds it weakly).
final class AttachmentPromise: NSFilePromiseProvider {
    private var strongDelegate: AttachmentPromiseDelegate?

    convenience init(fileType: String, delegate: AttachmentPromiseDelegate) {
        self.init(fileType: fileType, delegate: delegate)
        strongDelegate = delegate
    }
}

/// Writes a dragged attachment where it's dropped.
final class AttachmentPromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let model: AppModel
    private let messageId: Int64
    private let index: Int
    private let accountId: String
    private let part: MessagePart

    init(model: AppModel, messageId: Int64, index: Int, accountId: String, part: MessagePart) {
        self.model = model
        self.messageId = messageId
        self.index = index
        self.accountId = accountId
        self.part = part
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        AppModel.fileName(for: part)
    }

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void
    ) {
        nonisolated(unsafe) let done = completionHandler  // AppKit accepts the call from any thread.
        Task { @MainActor in
            do {
                let source = try await model.attachmentFile(
                    messageId: messageId, index: index, accountId: accountId, part: part)
                try FileManager.default.copyItem(at: source, to: url)
                try AppModel.quarantine(url)
                done(nil)
            } catch {
                done(error)
            }
        }
    }
}
