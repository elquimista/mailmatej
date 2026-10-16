import AppKit
import MailStore
import MailSync
import WebKit

/// Shows one message as a single web page: header fields, the remote-content bar and the body,
/// so they scroll together. Scripts never run. Embedded images always show; remote content is
/// blocked unless the user loads it, and trackers/insecure loads never load.
@MainActor
final class MessageViewController: NSViewController, WKNavigationDelegate {
    private let model: AppModel
    private let placeholder = NSTextField(labelWithString: "No Message Selected")
    private var webView: WKWebView!
    private let partHandler: EmbeddedPartSchemeHandler

    private var currentID: Int64?
    private var currentDetail: MessageDetail?
    private var currentBody: MessageBody?
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
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsMagnification = true

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
                if let name = a.name, !name.isEmpty { "\(name) <\(a.email)>" } else { a.email }
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
        applyRules(loadRemote: false)
        loadPage(content: "<p class=\"status\">\(MessagePage.escape(text))</p>", bar: nil, plain: false, remote: false)
    }

    private func render(_ body: MessageBody) {
        currentBody = body
        guard let html = body.html, let id = currentID else {
            applyRules(loadRemote: false)
            loadPage(content: MessagePage.escape(body.text ?? ""), bar: nil, plain: true, remote: false)
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
        let html = MessagePage.html(
            headers: headerFields, bar: bar, content: content, plain: plain, remote: remote, token: actionToken)
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
