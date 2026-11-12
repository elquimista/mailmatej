import AppKit
import MailStore
import MailSync
import WebKit

/// Several selected messages shown together, as MailMate shows them (see `MessageStackPage`): one page
/// in one web view, so a hundred messages take one web process, not a hundred (WebKit starts one per
/// web view). The page and each message's content are served from here (the mmj-stack scheme, so the
/// frames load with scripts off and share the page's origin); the app's scripts, in their own world,
/// size each message's frame to its content and pass on clicks on the bars and attachments.
@MainActor
final class MessageStack: NSObject, WKURLSchemeHandler, WKScriptMessageHandler, WKNavigationDelegate {
    private let model: AppModel
    private(set) var webView: MessageWebView!
    private let partHandler: EmbeddedPartSchemeHandler
    /// The page's height changed (points).
    var onHeight: (CGFloat) -> Void = { _ in }

    /// The messages shown, oldest first.
    private(set) var ids: [Int64] = []
    private var page = ""
    /// Bumped with each new set of messages: work for an earlier one is dropped.
    private var generation = 0
    private var accounts: [Int64: String] = [:]
    /// Messages whose remote content the user loaded.
    private var remoteIDs: Set<Int64> = []
    /// Each message's frame's content, bumped when it's to load anew.
    private var frameGenerations: [Int64: Int] = [:]
    private var bars: [Int64: MessagePage.Bar] = [:]
    private var parts: [Int64: [MessagePart]] = [:]
    private var files: [Int64: [MessageStackPage.Attachment]] = [:]
    private var shownDownloadAll = 0
    private var stopped = Set<ObjectIdentifier>()
    /// Bodies being downloaded, a few at a time (a hundred at once would flood the server).
    private var fetching = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(model: AppModel) {
        self.model = model
        partHandler = EmbeddedPartSchemeHandler(model: model)
        super.init()
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(self, forURLScheme: MessageStackPage.scheme)
        config.setURLSchemeHandler(partHandler, forURLScheme: MessageHTML.cidScheme)
        let scripts = config.userContentController
        scripts.addUserScript(WKUserScript(
            source: MessageViewController.heightScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        scripts.addUserScript(WKUserScript(source: Self.pageScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        scripts.addUserScript(WKUserScript(source: Self.frameScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient))
        scripts.add(WeakMessageHandler(self), contentWorld: .defaultClient, name: "mmjHeight")
        scripts.add(WeakMessageHandler(self), contentWorld: .defaultClient, name: "mmjStack")
        webView = MessageWebView(frame: .zero, configuration: config)
        // Clear between the cards, so the pane's background shows there (WebKit otherwise paints its own).
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.allowsMagnification = true
    }

    /// Shows these messages, oldest first as MailMate stacks them (the same ones again change nothing).
    func show(_ selection: [Int64]) {
        let rows = (try? model.store.rows(ids: selection)) ?? []
        let ordered = rows.sorted { ($0.receivedAt, $0.id) < ($1.receivedAt, $1.id) }.map(\.id)
        guard ordered != ids else { return }
        generation += 1
        ids = ordered
        (accounts, remoteIDs, frameGenerations, bars, parts, files, shownDownloadAll) = ([:], [], [:], [:], [:], [:], 0)
        partHandler.allowedMessageIDs = Set(ordered)
        var cards: [MessageStackPage.Card] = []
        for id in ordered {
            guard let detail = try? model.store.detail(id: id) else { continue }
            accounts[id] = detail.accountId
            cards.append(MessageStackPage.Card(id: id, fields: MessageViewController.fields(of: detail).map { ($0.label, $0.value) }))
        }
        page = MessageStackPage.html(cards: cards, detailsOpen: UserDefaults.standard.bool(forKey: "RemoteContentDetailsShown"))
        webView.resetHover()
        let current = generation
        Task {
            await applyRules()
            guard current == generation else { return }
            webView.load(URLRequest(url: URL(string: MessageStackPage.pageURL.absoluteString + "?\(current)")!))
        }
    }

    /// Shows nothing (another view took its place).
    func clear() {
        guard !ids.isEmpty else { return }
        generation += 1
        ids = []
        page = ""
        partHandler.allowedMessageIDs = []
        webView.loadHTMLString("", baseURL: nil)
    }

    // MARK: Remote content

    /// Remote content loads only for messages the user loaded it for, and only with the strict and
    /// script rules in place (fail closed). The rest stay blocked by their own page's policy; the block-all
    /// rules go too while none is loaded.
    private func remoteAllowed(_ id: Int64) -> Bool {
        remoteIDs.contains(id) && MessageViewController.strictRules != nil && MessageViewController.scriptRules != nil
    }

    private func applyRules() async {
        if let preparing = MessageViewController.preparingRules { await preparing.value }
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if let scripts = MessageViewController.scriptRules { controller.add(scripts) }
        if let strict = MessageViewController.strictRules { controller.add(strict) }
        if remoteIDs.isEmpty, let all = MessageViewController.blockAllRules { controller.add(all) }
    }

    /// Loads (or blocks again) the messages' remote content: their frames load anew.
    private func setRemote(_ changed: [Int64], _ on: Bool) {
        guard !changed.isEmpty else { return }
        for id in changed {
            if on { remoteIDs.insert(id) } else { remoteIDs.remove(id) }
        }
        let current = generation
        Task {
            await applyRules()
            guard current == generation else { return }
            for id in changed {
                let next = (frameGenerations[id] ?? 0) + 1
                frameGenerations[id] = next
                webView.callAsyncJavaScript(
                    "window.mmjFrame && mmjFrame(id, url)", arguments: ["id": id, "url": MessageStackPage.frameURL(id: id, generation: next)],
                    in: nil, in: .defaultClient)
            }
        }
    }

    /// What Download All loads: the remote content not loaded yet that isn't strictly blocked.
    private var downloadAll: Int {
        bars.values.filter { !$0.loaded }.reduce(0) { $0 + $1.remote - $1.strict }
    }

    /// Puts the message's attachments and bar in its card; every bar's Download All too when its count
    /// changed.
    private func fill(_ id: Int64) {
        let total = downloadAll
        let refill = total != shownDownloadAll ? ids.filter { $0 == id || bars[$0]?.loaded == false } : [id]
        shownDownloadAll = total
        for id in refill where parts[id] != nil {
            let html = MessageStackPage.extras(attachments: files[id] ?? [], bar: bars[id], downloadAll: total)
            webView.callAsyncJavaScript("window.mmjFill && mmjFill(id, html)", arguments: ["id": id, "html": html], in: nil, in: .defaultClient)
        }
    }

    // MARK: Serving

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        if url.path.isEmpty || url.path == "/" { return respond(task, page, policy: nil) }
        guard let (id, _) = MessageStackPage.frame(of: url), ids.contains(id) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let key = ObjectIdentifier(task)
        let current = generation
        Task {
            defer { stopped.remove(key) }
            let (html, remote) = await content(of: id)
            guard !stopped.contains(key), current == generation else { return }
            respond(task, html, policy: MessagePage.csp(remote: remote))
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    private func respond(_ task: any WKURLSchemeTask, _ html: String, policy: String?) {
        guard let url = task.request.url else { return }
        var headers = ["Content-Type": "text/html; charset=utf-8"]
        if let policy { headers["Content-Security-Policy"] = policy }
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(Data(html.utf8))
        task.didFinish()
    }

    /// A message's page, as the single message view makes it (downloaded first if it isn't stored), and
    /// whether its remote content may load; its attachments and bar go in its card meanwhile.
    private func content(of id: Int64) async -> (String, Bool) {
        let current = generation
        guard let accountId = accounts[id] else { return (status("Message Not Found"), false) }
        var body = try? model.store.body(messageId: id)
        if body == nil {
            await startFetching()
            defer { finishFetching() }
            guard current == generation else { return ("", false) }
            do {
                body = try await model.fetchBody(messageId: id, accountId: accountId)
            } catch let offline as SyncCoordinator.AccountOffline {
                return (status(offline.localizedDescription), false)
            } catch {
                return (status("Couldn’t load this message. " + AppModel.describe(error)), false)
            }
        }
        guard let body, current == generation else { return ("", false) }
        let messageParts = MessageViewController.attachments(messageId: id, html: body.html, store: model.store)
        parts[id] = messageParts
        files[id] = messageParts.map { part in
            let shown = MessageViewController.headerAttachment(part)
            return MessageStackPage.Attachment(name: shown.name, size: shown.size, icon: Self.dataURL(shown.icon))
        }
        guard let html = body.html else {
            bars[id] = nil
            fill(id)
            return (MessagePage.html(content: MessagePage.plainHTML(body.text ?? ""), plain: true, remote: false, adaptive: true, stacked: true), false)
        }
        let remote = remoteAllowed(id)
        let (prepared, page) = await Task.detached(priority: .userInitiated) {
            let prepared = MessageHTML.prepare(html, messageId: id, blockRemote: !remote)
            let adaptive = MessagePage.adapts(prepared.html, plain: false)
            return (prepared, MessagePage.html(content: prepared.html, plain: false, remote: remote, adaptive: adaptive, stacked: true))
        }.value
        guard current == generation else { return ("", false) }
        bars[id] = prepared.remoteCount == 0 ? nil : MessagePage.Bar(resources: prepared.resources, loaded: remote)
        fill(id)
        return (page, remote)
    }

    private func status(_ text: String) -> String {
        MessagePage.html(content: "<p class=\"status\">\(MessagePage.escape(text))</p>", plain: false, remote: false, adaptive: true, stacked: true)
    }

    private func startFetching() async {
        if fetching < 4 {
            fetching += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func finishFetching() {
        if waiting.isEmpty { fetching -= 1 } else { waiting.removeFirst().resume() }
    }

    /// The icon as a data: URL, made once per icon (the single view keeps one per file type).
    private static var iconURLs: [ObjectIdentifier: String] = [:]

    private static func dataURL(_ image: NSImage) -> String? {
        if let known = iconURLs[ObjectIdentifier(image)] { return known }
        guard let rep = image.representations.first as? NSBitmapImageRep, let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        let url = "data:image/png;base64," + png.base64EncodedString()
        iconURLs[ObjectIdentifier(image)] = url
        return url
    }

    // MARK: The page's messages

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            if message.name == "mmjHeight" {
                if let height = (message.body as? NSNumber)?.doubleValue { onHeight(min(CGFloat(height) * webView.magnification, 2_000_000)) }
                return
            }
            guard let body = message.body as? [String: Any], let id = (body["id"] as? NSNumber)?.int64Value, ids.contains(id),
                let action = body["action"] as? String
            else { return }
            switch action {
            case MessagePage.Action.load.rawValue: setRemote([id], true)
            case MessagePage.Action.reload.rawValue: setRemote([id], false)
            case "loadAll": setRemote(ids.filter { bars[$0].map { !$0.loaded && $0.remote > $0.strict } ?? false }, true)
            case "toggle": UserDefaults.standard.set(body["open"] as? Bool ?? false, forKey: "RemoteContentDetailsShown")
            case "open": openAttachment(of: id, (body["index"] as? NSNumber)?.intValue ?? -1)
            default: break
            }
        }
    }

    private func openAttachment(of id: Int64, _ index: Int) {
        guard let parts = parts[id], parts.indices.contains(index), let accountId = accounts[id] else { return }
        let part = parts[index]
        Task {
            do {
                NSWorkspace.shared.open(try await model.attachmentFile(messageId: id, index: index, accountId: accountId, part: part))
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t get “\(AppModel.fileName(for: part))”."
                alert.informativeText = AppModel.describe(error)
                if let window = webView.window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            }
        }
    }

    // MARK: Navigation

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        if navigationAction.navigationType == .linkActivated {
            // Clicked links open in the browser (only web and mail links).
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            return decisionHandler(.cancel)
        }
        // Only the pages served here (and the empty one). Anything else, such as a meta refresh to a
        // remote page where the message's policy would no longer apply, is refused.
        decisionHandler(url.scheme == "about" || url.scheme == MessageStackPage.scheme ? .allow : .cancel)
    }

    #if DEBUG
        /// Each card as drawn: its frame's height, its bar and buttons, its attachments, and its content's
        /// background (white for a light-only email in a dark stack).
        func debugCards() async -> String {
            let result = try? await webView.callAsyncJavaScript(
                """
                return [...document.querySelectorAll('mmj-card')].map(c => {
                  const f = c.querySelector('iframe'), d = f && f.contentDocument, bar = c.querySelector('mmj-bar');
                  const buttons = [...c.querySelectorAll('mmj-button')].map(b => b.textContent).join('+');
                  const bg = d && d.documentElement ? getComputedStyle(d.documentElement).backgroundColor : '-';
                  return c.id + ' frame=' + (f ? f.style.height : '-') + ' files=' + c.querySelectorAll('mmj-file').length
                    + ' bar=' + (bar ? bar.className + ':' + bar.querySelector('span').textContent + ' [' + buttons + ']' : '-') + ' bg=' + bg;
                }).join(' | ');
                """, arguments: [:], in: nil, contentWorld: .defaultClient)
            return result as? String ?? "-"
        }
    #endif

    // MARK: Scripts

    /// The page's own: fills in a card's attachments and bar (`mmjFill`), loads a frame anew
    /// (`mmjFrame`), and passes on clicks: a bar's buttons, the bar itself (its details, for every
    /// card), and a double-click on an attachment.
    static let pageScript = """
        (() => {
          const post = (m) => window.webkit.messageHandlers.mmjStack.postMessage(m);
          window.mmjFill = (id, html) => { const c = document.getElementById('c' + id); if (c) c.querySelector('mmj-extras').innerHTML = html; };
          window.mmjFrame = (id, url) => { const f = document.getElementById('f' + id); if (f) f.src = url; };
          const cardOf = (e) => { const c = e.target.closest && e.target.closest('mmj-card'); return c ? Number(c.id.slice(1)) : null; };
          document.addEventListener('click', (e) => {
            const id = cardOf(e);
            if (id === null) return;
            const button = e.target.closest('mmj-button');
            if (button) return post({ id, action: button.dataset.act });
            if (e.target.closest('mmj-bar')) post({ id, action: 'toggle', open: document.body.classList.toggle('mmj-open') });
          }, true);
          document.addEventListener('dblclick', (e) => {
            const id = cardOf(e), file = e.target.closest && e.target.closest('mmj-file');
            if (id !== null && file) post({ id, action: 'open', index: Number(file.dataset.i) });
          }, true);
        })();
        """

    /// Each message's frame: as tall as its content, kept so as it changes (images loading, the pane
    /// resized). The frames share the page's origin, so this sets the frame's own height.
    static let frameScript = """
        (() => {
          if (window === window.top || !window.frameElement) return;
          const frame = window.frameElement;
          let last = -1, pending = false;
          const fit = () => {
            pending = false;
            const end = document.querySelector('mmj-end');
            const height = Math.ceil(end ? end.getBoundingClientRect().top + window.scrollY : document.documentElement.scrollHeight);
            if (height !== last) { last = height; frame.style.height = height + 'px'; }
          };
          const schedule = () => { if (!pending) { pending = true; setTimeout(fit, 0); } };
          const observer = new ResizeObserver(schedule);
          observer.observe(document.documentElement);
          if (document.body) observer.observe(document.body);
          document.addEventListener('load', schedule, true);
          schedule();
        })();
        """
}
