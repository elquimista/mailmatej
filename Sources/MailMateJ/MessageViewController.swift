import AppKit
import MailStore
import MailSync
import Quartz
import UniformTypeIdentifiers
import WebKit

/// Shows one message: the native header block (fields, attachments, remote-content bar) over the
/// message content in a web view, one under the other in a native scroll view, so they scroll together
/// as in MailMate while the email's CSS can't reach the headers. The web view is as tall as its content
/// (a script in the app's own world reports the height as it changes). Scripts never run. Embedded
/// images always show; remote content is blocked unless the user loads it, and trackers/insecure loads
/// never load.
@MainActor
final class MessageViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {
    private let model: AppModel
    private let placeholder = NSTextField(labelWithString: "No Message Selected")
    private let linkPreview = LinkPreviewView()
    private var webView: MessageWebView!
    private let header = MessageHeaderView()
    private let scroll = MessageScrollView()
    private let document = FlippedView()
    /// The content's height as the page last reported it (points).
    private var contentHeight: CGFloat = 0
    private let partHandler: EmbeddedPartSchemeHandler

    private var currentID: Int64?
    /// A message was put on screen (on its own, not as one of several selected).
    var onDisplay: ((Int64) -> Void)?

    /// The message on screen, if one real message is shown.
    var displayedMessageID: Int64? { currentID.flatMap { $0 > 0 && currentDetail != nil ? $0 : nil } }
    private var currentDetail: MessageDetail?
    private var currentBody: MessageBody?
    /// Files attached to the message on screen, in the order shown.
    private var attachments: [MessagePart] = []
    /// The file Quick Look shows.
    private var previewURLs: [URL] = []
    /// Whether the page shows the buttons' ⌥ variants (⌥ is held).
    private var showsOptionVariants = false
    private var flagsMonitor: Any?
    /// The user clicked Load for the message on screen.
    private var loadRemoteForCurrent = false

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
        // The content's height, from the app's own script world (the email can't see or affect it).
        config.userContentController.addUserScript(WKUserScript(
            source: Self.heightScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        config.userContentController.add(WeakMessageHandler(self), contentWorld: .defaultClient, name: "mmjHeight")
        webView = MessageWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsMagnification = true

        header.onOpen = { [weak self] in self?.openAttachment($0) }
        header.onQuickLook = { [weak self] in self?.quickLookAttachment($0) }
        header.onSelectAttachment = { [weak self] index in
            // Quick Look, while open, shows the attachment the selection moved to.
            guard QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared()?.isVisible == true else { return }
            self?.quickLookAttachment(index)
        }
        // As MailMate's download button: saves to Downloads; with ⌥, asks where to save.
        header.onSave = { [weak self] index, option in option ? self?.saveAttachment(index) : self?.saveAttachmentToDownloads(index) }
        header.menuForAttachment = { [weak self] in self?.attachmentMenu($0) }
        header.dragItem = { [weak self] in self?.draggingItem(forAttachment: $0) }
        header.onBarAction = { [weak self] action, button in self?.perform(action, from: button) }
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
        webView.onHoverLink = { [weak self] in self?.showLinkPreview($0) }

        placeholder.font = .systemFont(ofSize: 15, weight: .medium)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center

        document.addSubview(header)
        document.addSubview(webView)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipResized), name: NSView.frameDidChangeNotification, object: scroll.contentView)

        let root = NSView()
        linkPreview.isHidden = true
        for v in [scroll, placeholder, linkPreview] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            // MailMate's: at the pane's bottom, 2 px left of the body text (14 px margin).
            linkPreview.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            linkPreview.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -1),
            linkPreview.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
        ])
        view = root
        showPlaceholder("No Message Selected")
    }

    // MARK: Layout

    /// Reports the content's height whenever it changes (images loading, the pane resized): the end
    /// marker's position, which the page puts right after the content.
    private static let heightScript = """
        (() => {
          let last = -1, pending = false;
          const report = () => {
            pending = false;
            const end = document.querySelector('mmj-end');
            const height = Math.ceil(end ? end.getBoundingClientRect().top + window.scrollY : document.body.scrollHeight);
            if (height !== last) { last = height; window.webkit.messageHandlers.mmjHeight.postMessage(height); }
          };
          const schedule = () => { if (!pending) { pending = true; setTimeout(report, 0); } };
          const observer = new ResizeObserver(schedule);
          observer.observe(document.documentElement);
          if (document.body) observer.observe(document.body);
          document.addEventListener('load', schedule, true);
          schedule();
        })();
        """

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            if let height = (message.body as? NSNumber)?.doubleValue { contentHeightChanged(height) }
        }
    }

    /// Points: the page measures in CSS pixels, which zooming scales. Capped against a page that grows
    /// with its own view (`min-height: 120vh`).
    private func contentHeightChanged(_ height: Double) {
        let points = min(CGFloat(height) * webView.magnification, 200_000)
        guard points != contentHeight else { return }
        contentHeight = points
        layoutDocument()
    }

    /// Measures the content once more when the page has loaded (the script reports changes after that).
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.callAsyncJavaScript(
            "const e = document.querySelector('mmj-end'); return e ? Math.ceil(e.getBoundingClientRect().top + window.scrollY) : 0;",
            arguments: [:], in: nil, in: .defaultClient
        ) { [weak self] result in
            if let height = (try? result.get()) as? Double, height > 0 { self?.contentHeightChanged(height) }
        }
    }

    @objc private func clipResized() { layoutDocument() }

    /// The header on top, the content under it, as tall as the content (and at least down to the
    /// pane's bottom, so the page's background fills it).
    private func layoutDocument() {
        let width = scroll.contentView.bounds.width
        let headerHeight = header.height(forWidth: width)
        let webHeight = max(contentHeight, scroll.contentView.bounds.height - headerHeight)
        header.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight)
        webView.frame = NSRect(x: 0, y: headerHeight, width: width, height: webHeight)
        document.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight + webHeight)
    }

    func show(messageID: Int64?, selectionCount: Int = 1) {
        guard let messageID else {
            currentID = nil
            showPlaceholder(selectionCount > 1 ? "\(selectionCount) Messages Selected" : "No Message Selected")
            return
        }
        guard messageID != currentID else { return }
        scroll.contentView.scroll(to: .zero)  // a new message starts at its top
        scroll.reflectScrolledClipView(scroll.contentView)
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
        scroll.isHidden = false
        onDisplay?(messageID)

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
            } catch let offline as SyncCoordinator.AccountOffline {
                guard currentID == messageID else { return }
                showStatus(offline.localizedDescription)  // nothing went wrong
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
        renderGeneration += 1  // a page still being prepared doesn't show over this
        placeholder.stringValue = text
        placeholder.isHidden = false
        scroll.isHidden = true
        currentDetail = nil
        header.update(fields: [], attachments: [], bar: nil)
        webView.loadHTMLString("", baseURL: nil)
    }

    /// The address of the link under the pointer, as MailMate shows it, so it can be checked before
    /// clicking. Shown and hidden at once (no fade).
    private func showLinkPreview(_ href: String?) {
        linkPreview.text = href ?? ""
        linkPreview.isHidden = href?.isEmpty ?? true
    }

    // MARK: Rendering

    private var currentSender: String? { currentDetail?.addresses(.from).first?.email }

    private var headerFields: [MessageHeaderView.Field] {
        guard let detail = currentDetail else { return [] }
        func list(_ role: AddressRole, groups: AddressRole? = nil) -> String {
            // Empty groups show by name, as MailMate shows "undisclosed-recipients".
            (detail.addresses(role).map { a in
                // A name that's just the address again is left out, as MailMate does.
                if let name = a.name, !name.isEmpty, name.caseInsensitiveCompare(a.email) != .orderedSame {
                    "\(name) <\(a.email)>"
                } else {
                    a.email
                }
            } + (groups.map { detail.addresses($0).compactMap(\.name) } ?? [])).joined(separator: ", ")
        }
        return [
            .init(label: "From:", value: list(.from)),
            .init(label: "Subject:", value: detail.subject),
            .init(label: "Date:", value: Formatters.fullDate(detail.sentAt ?? detail.receivedAt)),
            .init(label: "To:", value: list(.to, groups: .toGroup)),
            .init(label: "Cc:", value: list(.cc, groups: .ccGroup)),
            .init(label: "Bcc:", value: list(.bcc)),
        ]
    }

    private func showStatus(_ text: String) {
        renderGeneration += 1  // a page still being prepared doesn't show over this
        attachments = []
        applyRules(loadRemote: false)
        loadPage(content: "<p class=\"status\">\(MessagePage.escape(text))</p>", bar: nil, plain: false, remote: false)
    }

    /// Bumped by each render: a page prepared in the background shows only if no render came after it.
    private var renderGeneration = 0

    private func render(_ body: MessageBody) {
        renderGeneration += 1
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
        let canAlwaysLoad = currentSender != nil
        func show(_ prepared: PreparedHTML, page: String) {
            let bar = prepared.remoteCount == 0 ? nil : MessagePage.Bar(
                remote: prepared.remoteCount, strict: prepared.strictCount, loaded: loadRemote,
                canAlwaysLoad: canAlwaysLoad, allowedBy: allowedBy)
            applyRules(loadRemote: loadRemote)
            loadPage(page, bar: bar)
        }
        @Sendable nonisolated func prepare() -> (PreparedHTML, String) {
            let prepared = MessageHTML.prepare(html, messageId: id, blockRemote: !loadRemote)
            return (prepared, MessagePage.html(content: prepared.html, plain: false, remote: loadRemote))
        }
        // Most messages take a few milliseconds; a big newsletter (they run to a megabyte) up to 70, so
        // it's prepared off the main thread, the message shown before staying until it's ready.
        guard html.utf8.count > 100_000 else {
            let (prepared, page) = prepare()
            return show(prepared, page: page)
        }
        let generation = renderGeneration
        Task {
            let (prepared, page) = await Task.detached(priority: .userInitiated) { prepare() }.value
            guard generation == renderGeneration else { return }
            show(prepared, page: page)
        }
    }

    private func rerender() {
        if let currentBody { render(currentBody) }
    }

    private func loadPage(content: String, bar: MessagePage.Bar?, plain: Bool, remote: Bool) {
        loadPage(MessagePage.html(content: content, plain: plain, remote: remote), bar: bar)
    }

    private func loadPage(_ html: String, bar: MessagePage.Bar?) {
        webView.resetHover()
        header.update(fields: headerFields, attachments: attachments.map(Self.headerAttachment), bar: bar)
        showsOptionVariants = false
        header.showsOptionVariants = NSEvent.modifierFlags.contains(.option)
        contentHeight = 0  // until the new page reports its own
        layoutDocument()
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

    static func headerAttachment(_ part: MessagePart) -> MessageHeaderView.Attachment {
        let name = AppModel.fileName(for: part)
        let ext = (name as NSString).pathExtension.lowercased()
        let type = UTType(filenameExtension: ext) ?? UTType(mimeType: part.type) ?? .data
        return MessageHeaderView.Attachment(name: name, size: part.size.map(Self.binarySize) ?? "", icon: icon(for: type))
    }

    private static var iconCache: [String: NSImage] = [:]

    /// The type's Finder icon, drawn at 40 px and shown at 20 pt (sharp on Retina, and at 1x the same
    /// pixels MailMate shows), cached per type.
    private static func icon(for type: UTType) -> NSImage {
        if let cached = iconCache[type.identifier] { return cached }
        let image = NSImage(size: NSSize(width: 20, height: 20))
        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSWorkspace.shared.icon(for: type).draw(in: NSRect(x: 0, y: 0, width: 40, height: 40))
            NSGraphicsContext.restoreGraphicsState()
            rep.size = NSSize(width: 20, height: 20)
            image.addRepresentation(rep)
        }
        iconCache[type.identifier] = image
        return image
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
            showQuickLook([url], panel: panel)
        }
    }

    private func showQuickLook(_ urls: [URL], panel: QLPreviewPanel) {
        previewURLs = urls
        // The panel asks the responder chain for its controller: this view's, unless the focus is in it
        // already (a selected attachment keeps it).
        if !((view.window?.firstResponder as? NSView)?.isDescendant(of: view) ?? false) {
            view.window?.makeFirstResponder(webView)
        }
        if panel.isVisible { panel.reloadData() } else { panel.makeKeyAndOrderFront(nil) }
    }

    // MARK: All attachments (Message menu)

    var hasAttachments: Bool { !attachments.isEmpty }

    /// Every attachment as a file, in the message's order; reports the first one that couldn't be fetched.
    private func withAllAttachmentFiles(_ body: @escaping @MainActor ([URL]) -> Void) {
        guard !attachments.isEmpty, let id = currentID, let detail = currentDetail else { return NSSound.beep() }
        let parts = attachments
        Task { @MainActor in
            var urls: [URL] = []
            for (index, part) in parts.enumerated() {
                do {
                    urls.append(try await model.attachmentFile(messageId: id, index: index, accountId: detail.accountId, part: part))
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t get “\(AppModel.fileName(for: part))”."
                    alert.informativeText = AppModel.describe(error)
                    if let window = view.window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
                    return
                }
            }
            body(urls)
        }
    }

    func quickLookAllAttachments() {
        withAllAttachmentFiles { [weak self] urls in
            guard let self, let panel = QLPreviewPanel.shared() else { return }
            showQuickLook(urls, panel: panel)
        }
    }

    func openAllAttachments() {
        withAllAttachmentFiles { urls in urls.forEach { NSWorkspace.shared.open($0) } }
    }

    /// Saves every attachment into a folder the user picks.
    func saveAllAttachments() {
        guard hasAttachments, let window = view.window else { return NSSound.beep() }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save"
        panel.message = "Choose where to save the attachments."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            self?.withAllAttachmentFiles { urls in
                for source in urls {
                    let target = Self.unusedURL(folder.appendingPathComponent(source.lastPathComponent))
                    guard self?.copy(source, to: target, replacing: false) == true else { return }
                }
            }
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
        item.setDraggingFrame(NSRect(x: 0, y: 0, width: 32, height: 32), contents: NSWorkspace.shared.icon(for: type))
        return item  // placed under the pointer by the row
    }

    private func showOptionVariants(_ on: Bool) {
        showsOptionVariants = on
        header.showsOptionVariants = on
    }

    /// Keys released while another app is in front never reach us.
    @objc private func appResignedActive() { showOptionVariants(false) }

    @objc private func syncOptionKey() { showOptionVariants(NSEvent.modifierFlags.contains(.option)) }

    // MARK: Quick Look

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

    // MARK: Remote-content actions

    private func perform(_ action: MessagePage.Action, from button: NSView? = nil) {
        switch action {
        case .load:
            loadRemoteForCurrent = true
            rerender()
        case .alwaysLoadMenu:
            showAlwaysLoadMenu(under: button)
        case .stopAlwaysLoading:
            guard let sender = currentSender else { return }
            for entry in (try? model.store.remoteContentAllowEntries(email: sender)) ?? [] {
                try? model.store.disallowRemoteContent(entry)
            }
            loadRemoteForCurrent = false
            rerender()
        }
    }

    private func showAlwaysLoadMenu(under button: NSView?) {
        guard let sender = currentSender, let anchor = button ?? view.window?.contentView else { return }
        let menu = NSMenu()
        menu.addItem(alwaysLoadItem(title: sender, value: sender))
        if let domain = sender.split(separator: "@").last {
            menu.addItem(alwaysLoadItem(title: "Anyone at \(domain)", value: "@\(domain)"))
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.isFlipped ? anchor.bounds.height + 2 : -2), in: anchor)
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

    /// Loads the blocked remote content of the message on screen, this once (the bar's Load).
    func loadRemoteContentOnce() {
        guard displayedMessageID != nil else { return NSSound.beep() }
        perform(.load)
    }

    #if DEBUG
        func debugLoadRemote() { perform(.load) }

        /// The message on show, or the placeholder's text.
        var debugShowing: String { placeholder.isHidden ? "message \(currentID ?? -1)" : "“\(placeholder.stringValue)”" }

        var debugAttachmentRows: [String] { header.debugAttachmentRows }
        func debugAttachment(click index: Int?, key: UInt16? = nil) { header.debugAttachment(click: index, key: key) }

        /// Logs the attachments, Quick Looks the second with MMJ_DEBUG_QUICKLOOK, and fetches the first to a
        /// file (without opening it), logging its path and quarantine flag.
        func debugCheckAttachments() async {
            NSLog("MMJ attachments: \(attachments.map { AppModel.fileName(for: $0) })")
            NSLog("MMJ attachment menu: \(attachmentMenu(1)?.items.map(\.title) ?? [])")
            if ProcessInfo.processInfo.environment["MMJ_DEBUG_OPTION"] != nil {
                showOptionVariants(true)
                NSLog("MMJ attachment option state: \(header.showsOptionVariants)")
                syncOptionKey()  // As after the save panel closes, with ⌥ not held.
                NSLog("MMJ attachment option state after sync: \(header.showsOptionVariants)")
            }
            if ProcessInfo.processInfo.environment["MMJ_DEBUG_QUICKLOOK"] != nil {
                quickLookAttachment(1)
                try? await Task.sleep(for: .seconds(2))
                NSLog("MMJ attachment Quick Look visible: \(QLPreviewPanel.shared()?.isVisible ?? false) item=\(previewURLs.first?.lastPathComponent ?? "none")")
            }
            withAttachmentFile(0) { url in
                let q = (try? url.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties
                NSLog("MMJ attachment file: \(url.path) size=\((try? Data(contentsOf: url))?.count ?? -1) quarantine=\(q != nil)")
            }
        }

        /// Shows arbitrary HTML through the normal pipeline (prepare, page, content rules).
        func debugHoverLink(containing text: String) async { await webView.debugHoverLink(containing: text) }

        func debugRender(html: String) {
            currentID = -1  // Keeps the selected message's header, if any.
            partHandler.allowedMessageID = -1
            placeholder.isHidden = true
            scroll.isHidden = false
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

        /// Scrolls the message, as the scroll wheel over its content would.
        func debugScrollContent(by points: CGFloat) {
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-points), wheel2: 0, wheel3: 0),
                let nsEvent = NSEvent(cgEvent: event)
            else { return }
            webView.scrollWheel(with: nsEvent)
        }

        /// The header's and content's frames and the scroll position, for checking the layout.
        var debugLayout: String {
            "header \(NSStringFromRect(header.frame)) web \(NSStringFromRect(webView.frame)) content \(contentHeight) "
                + "document \(NSStringFromRect(document.frame)) scrolled \(scroll.contentView.bounds.origin.y)"
        }
    #endif

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        if navigationAction.navigationType == .linkActivated {
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
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
        MainActor.assumeIsolated { previewURLs.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url: URL? = MainActor.assumeIsolated { previewURLs.indices.contains(index) ? previewURLs[index] : nil }
        return url as NSURL?
    }
}

/// Keeps its delegate alive for the length of the drag (the provider holds it weakly).
final class AttachmentPromise: NSFilePromiseProvider {
    private var strongDelegate: AttachmentPromiseDelegate?

    convenience init(fileType: String, delegate: AttachmentPromiseDelegate) {
        self.init(fileType: fileType, delegate: delegate as any NSFilePromiseProviderDelegate)
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

/// MailMate's link preview: the URL in black 13 pt on a light rounded box, 25 px tall, in light and
/// dark mode alike (measured at 1x: top 240, bottom 228, 4 px corners, text 6 px in from the edge).
/// AppKit draws these greys lighter on this display, so the drawn values are lower.
final class LinkPreviewView: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.textColor = .black
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 25),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),  // the field's inset makes 6
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let gradient = NSGradient(
            starting: NSColor(srgbRed: 222 / 255, green: 222 / 255, blue: 222 / 255, alpha: 1),
            ending: NSColor(srgbRed: 238 / 255, green: 238 / 255, blue: 238 / 255, alpha: 1))
        gradient?.draw(in: NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4), angle: 90)
    }

    // Clicks and hovering go to the message underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The message's scroll view: the header and content scroll in it together. Paging keys pressed in
/// the content come here (see MessageWebView).
final class MessageScrollView: NSScrollView {
    /// A page down (1) or up (-1), keeping a line of the previous page in view, as scroll views do.
    func page(_ direction: CGFloat) {
        scroll(by: direction * max(contentView.bounds.height - verticalPageScroll - 24, 24))
    }

    func line(_ direction: CGFloat) { scroll(by: direction * 40) }

    func toEdge(top: Bool) {
        scroll(by: top ? -.greatestFiniteMagnitude : .greatestFiniteMagnitude)
    }

    private func scroll(by delta: CGFloat) {
        guard let document = documentView else { return }
        let maxY = max(0, document.frame.height - contentView.bounds.height)
        let y = min(max(contentView.bounds.origin.y + delta, 0), maxY)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            contentView.animator().setBoundsOrigin(NSPoint(x: contentView.bounds.origin.x, y: y))
        }
        reflectScrolledClipView(contentView)
    }
}

/// Passes script messages on without the user content controller keeping the receiver alive.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
