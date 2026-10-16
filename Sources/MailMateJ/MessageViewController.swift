import AppKit
import MailStore
import MailSync
import WebKit

/// Header fields plus the rendered body. JavaScript is off. Embedded images always show;
/// remote content is blocked unless the user loads it, and trackers/insecure loads never load.
@MainActor
final class MessageViewController: NSViewController, WKNavigationDelegate {
    private let model: AppModel
    private let grid = NSGridView()
    private let headerContainer = NSView()
    private let placeholder = NSTextField(labelWithString: "No Message Selected")
    private let remoteBar = RemoteContentBar()
    private var remoteBarHeight: NSLayoutConstraint!
    private var webView: WKWebView!
    private let partHandler: EmbeddedPartSchemeHandler

    private var currentID: Int64?
    private var currentSender: String?
    private var currentBody: MessageBody?
    /// The user clicked Load for the message on screen.
    private var loadRemoteForCurrent = false

    /// Blocks every network load. Attached unless the user loads remote content.
    private static var blockAllRules: WKContentRuleList?
    /// Blocks trackers and insecure loads. Always attached.
    private static var strictRules: WKContentRuleList?

    init(model: AppModel) {
        self.model = model
        partHandler = EmbeddedPartSchemeHandler(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = true
        config.setURLSchemeHandler(partHandler, forURLScheme: MessageHTML.cidScheme)
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsMagnification = true

        grid.rowSpacing = 3
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(grid)
        buildHeaderRows()

        let separator = NSBox()
        separator.boxType = .separator

        placeholder.font = .systemFont(ofSize: 15, weight: .medium)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center

        let root = NSView()
        remoteBar.onLoad = { [weak self] in
            self?.loadRemoteForCurrent = true
            self?.rerender()
        }
        remoteBar.onAlwaysLoad = { [weak self] value in
            try? self?.model.store.allowRemoteContent(value)
            self?.rerender()
        }
        remoteBar.onStopAlwaysLoading = { [weak self] in
            guard let self, let sender = currentSender else { return }
            for entry in (try? model.store.remoteContentAllowEntries(email: sender)) ?? [] {
                try? model.store.disallowRemoteContent(entry)
            }
            loadRemoteForCurrent = false
            rerender()
        }
        remoteBarHeight = remoteBar.heightAnchor.constraint(equalToConstant: 0)

        for v in [headerContainer, separator, remoteBar, webView!, placeholder] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            headerContainer.topAnchor.constraint(equalTo: root.topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            grid.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 10),
            grid.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 14),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: headerContainer.trailingAnchor, constant: -14),
            grid.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: -10),
            separator.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            remoteBar.topAnchor.constraint(equalTo: separator.bottomAnchor),
            remoteBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            remoteBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            remoteBarHeight,
            webView.topAnchor.constraint(equalTo: remoteBar.bottomAnchor),
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
        setRemoteBar(visible: false)
        guard let detail = try? model.store.detail(id: messageID) else {
            showPlaceholder("Message Not Found")
            return
        }
        currentSender = detail.addresses(.from).first?.email
        placeholder.isHidden = true
        headerContainer.isHidden = false
        webView.isHidden = false
        fillHeader(detail)

        if let body = try? model.store.body(messageId: messageID) {
            render(body)
            return
        }
        loadHTML(Self.page(body: "<p class='status'>Loading…</p>", plain: false))
        Task {
            do {
                let body = try await model.fetchBody(messageId: messageID, accountId: detail.accountId)
                guard currentID == messageID else { return }
                render(body)
            } catch {
                guard currentID == messageID else { return }
                loadHTML(Self.page(body: "<p class='status'>Couldn’t load this message. \(Self.escape(AppModel.describe(error)))</p>", plain: false))
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
        headerContainer.isHidden = true
        webView.isHidden = true
        setRemoteBar(visible: false)
        webView.loadHTMLString("", baseURL: nil)
    }

    private enum HeaderField: Int, CaseIterable {
        case from, subject, date, to, cc

        var label: String {
            switch self {
            case .from: "From:"
            case .subject: "Subject:"
            case .date: "Date:"
            case .to: "To:"
            case .cc: "Cc:"
            }
        }
    }

    private var headerValues: [HeaderField: NSTextField] = [:]

    /// Creates one row per header field. Rows are reused and hidden when empty; `NSGridView.removeRow`
    /// leaves the row's views behind as subviews, so rows must never be removed and re-added.
    private func buildHeaderRows() {
        for field in HeaderField.allCases {
            let label = NSTextField(labelWithString: field.label)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.font = .systemFont(ofSize: NSFont.systemFontSize - 1)
            let value = NSTextField(wrappingLabelWithString: "")
            value.isSelectable = true
            value.font = field == .subject
                ? .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
                : .systemFont(ofSize: NSFont.systemFontSize - 1)
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            grid.addRow(with: [label, value])
            headerValues[field] = value
        }
        grid.column(at: 0).xPlacement = .trailing
    }

    private func fillHeader(_ detail: MessageDetail) {
        func list(_ role: AddressRole) -> String {
            detail.addresses(role).map { a in
                if let name = a.name, !name.isEmpty { "\(name) <\(a.email)>" } else { a.email }
            }.joined(separator: ", ")
        }
        let values: [HeaderField: String] = [
            .from: list(.from), .subject: detail.subject,
            .date: Formatters.fullDate(detail.sentAt ?? detail.receivedAt), .to: list(.to), .cc: list(.cc),
        ]
        for field in HeaderField.allCases {
            let value = values[field] ?? ""
            headerValues[field]?.stringValue = value
            grid.row(at: field.rawValue).isHidden = value.isEmpty
        }
    }

    private func render(_ body: MessageBody) {
        currentBody = body
        guard let html = body.html, let id = currentID else {
            setRemoteBar(visible: false)
            applyRules(loadRemote: false)
            loadHTML(Self.page(body: Self.escape(body.text ?? ""), plain: true))
            return
        }
        let prepared = MessageHTML.prepare(html, messageId: id)
        let allowedBy = currentSender.flatMap { try? model.store.remoteContentAllowEntries(email: $0) } ?? []
        // Fail closed: remote content only loads when the strict rules are in place.
        let loadRemote = (loadRemoteForCurrent || !allowedBy.isEmpty) && Self.strictRules != nil
        applyRules(loadRemote: loadRemote)
        loadHTML(Self.page(body: prepared.html, plain: false, remote: loadRemote))

        if prepared.remoteCount > 0 {
            remoteBar.update(
                remote: prepared.remoteCount, strict: prepared.strictCount, loaded: loadRemote, sender: currentSender,
                allowedBy: allowedBy)
            setRemoteBar(visible: true)
        } else {
            setRemoteBar(visible: false)
        }
    }

    #if DEBUG
        func debugLoadRemote() { remoteBar.onLoad?() }
    #endif

    private func rerender() {
        if let currentBody { render(currentBody) }
    }

    private func setRemoteBar(visible: Bool) {
        remoteBar.isHidden = !visible
        remoteBarHeight.constant = visible ? 30 : 0
    }

    private func applyRules(loadRemote: Bool) {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if let strict = Self.strictRules { controller.add(strict) }
        if !loadRemote, let all = Self.blockAllRules { controller.add(all) }
    }

    private func loadHTML(_ html: String) {
        webView.loadHTMLString(html, baseURL: nil)
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
        } catch {
            NSLog("MailMateJ: could not compile remote-content rules: \(error)")
        }
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // MARK: HTML

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Wraps message content in a page whose Content-Security-Policy is a second line of defense
    /// behind the content rules: only embedded parts and data: URLs, plus https when `remote`.
    static func page(body: String, plain: Bool, remote: Bool = false) -> String {
        let https = remote ? " https:" : ""
        let csp = "default-src 'none'; style-src 'unsafe-inline'\(https); img-src data: \(MessageHTML.cidScheme):\(https); "
            + "font-src data:\(https); media-src \(MessageHTML.cidScheme):"
        if plain {
            return """
                <!doctype html><html><head><meta charset="utf-8">
                <meta http-equiv="Content-Security-Policy" content="\(csp)">
                <meta name="color-scheme" content="light dark">
                <style>
                  body { font: 13px -apple-system, sans-serif; margin: 14px; white-space: pre-wrap;
                         overflow-wrap: anywhere; line-height: 1.45; }
                  .status { color: GrayText; }
                </style></head><body>\(body)</body></html>
                """
        }
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="\(csp)">
            <style>.status { font: 13px -apple-system, sans-serif; color: GrayText; margin: 14px; }</style>
            </head><body>\(body)</body></html>
            """
    }
}
