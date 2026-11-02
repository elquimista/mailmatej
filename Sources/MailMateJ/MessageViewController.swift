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
    /// The raw source's page (View ▸ Show Raw Message), under the message's until it has drawn, so the
    /// two change places at once.
    private var rawView: MessageWebView!
    /// The web view on screen: the raw source's while it shows, else the message's.
    private var shownWebView: MessageWebView { rawShown ? rawView : webView }
    private let header = MessageHeaderView()
    private let scroll = MessageScrollView()
    private let document = FlippedView()
    /// The content's height as the page last reported it (points).
    private var contentHeight: CGFloat = 0
    /// The raw source page's, as `contentHeight`.
    private var rawHeight: CGFloat = 0
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

    /// A message page's settings: three independent locks on scripts (JavaScript off, `script-src 'none'`
    /// in the page CSP, a content rule blocking script loads), and the app's own scripts, in their own
    /// world (the email can't see or affect them): the content's height, and marking.
    private func pageConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = true
        config.userContentController.addUserScript(WKUserScript(
            source: Self.heightScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        config.userContentController.add(WeakMessageHandler(self), contentWorld: .defaultClient, name: "mmjHeight")
        config.userContentController.addUserScript(WKUserScript(
            source: Self.markScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        return config
    }

    override func loadView() {
        let config = pageConfiguration()
        config.setURLSchemeHandler(partHandler, forURLScheme: MessageHTML.cidScheme)
        webView = MessageWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsMagnification = true
        // Its page loads nothing at all (its CSP); no rules to change.
        rawView = MessageWebView(frame: .zero, configuration: pageConfiguration())
        rawView.navigationDelegate = self
        rawView.isHidden = true
        // WebKit starts a page's process with its first load (some 50 ms): done ahead, once the window has
        // settled, so the first Show Raw Message is as quick as the rest.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, rawLoads == 0 else { return }
            rawView.loadHTMLString("", baseURL: nil)
        }

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
        header.onResize = { [weak self] in self?.layoutDocument() }
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

        document.addSubview(rawView)  // under the message, until it has drawn
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
        findBar.isHidden = true
        findBar.onChange = { [weak self] in self?.find($0) }
        findBar.onNext = { [weak self] in self?.findNext(forward: true) }
        findBar.onPrevious = { [weak self] in self?.findNext(forward: false) }
        findBar.onDone = { [weak self] in self?.hideFind() }
        for v in [scroll, placeholder, linkPreview, findBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: root.topAnchor),
            findBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            findBar.heightAnchor.constraint(equalToConstant: MessageFindBar.height),
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
        scrollTop = scroll.topAnchor.constraint(equalTo: root.topAnchor)
        scrollTop?.isActive = true
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

    /// `mmjMark(terms, joinSpaced)`, in the app's own script world: marks where the message's text shows
    /// the search's terms (`SearchHighlight`s: a word, or a phrase whose words any spacing separates;
    /// ignoring case and accents; only where a word starts unless `wordStart` is false), wrapping them in
    /// `mmj-mark`, which the page's CSS colors. The marks made before go first. Elements that start a
    /// block (and `br`) part words, as on screen (a U+2029 in the text searched). With `joinSpaced`,
    /// marks of the same `group` only spaces part are joined into one, within a block. Returns how many
    /// places it marked; each place's marks are numbered (`data-n`) for `mmjCurrent(n)`, which makes
    /// place `n` Find's current one (yellow; -1 for none) and returns its top and bottom on the page.
    private static let markScript = """
        window.mmjCurrent = (n) => {
          let top = Infinity, bottom = -Infinity;
          for (const mark of document.querySelectorAll('mmj-mark')) {
            const on = mark.dataset.n === String(n);
            mark.toggleAttribute('current', on);
            if (on) { const b = mark.getBoundingClientRect(); top = Math.min(top, b.top + window.scrollY); bottom = Math.max(bottom, b.bottom + window.scrollY); }
          }
          return top === Infinity ? null : [top, bottom];
        };
        window.mmjMark = (terms, joinSpaced) => {
          const parents = new Set();
          for (const mark of document.querySelectorAll('mmj-mark')) { parents.add(mark.parentNode); mark.replaceWith(...mark.childNodes); }
          parents.forEach(p => p.normalize());
          const root = document.querySelector('mmj-content');
          if (!root || !terms.length) return 0;
          const fold = (s) => {
            let out = '';
            for (let i = 0; i < s.length; i++) {
              const code = s.charCodeAt(i);
              if (code < 128) { out += code >= 65 && code <= 90 ? String.fromCharCode(code + 32) : s[i]; continue; }
              const plain = s[i].normalize('NFD').replace(/\\p{M}/gu, '').toLowerCase(), lower = s[i].toLowerCase();
              out += plain.length === 1 ? plain : lower.length === 1 ? lower : s[i];  // one for one, so offsets hold
            }
            return out;
          };
          const blocks = new Set(['ADDRESS', 'ARTICLE', 'ASIDE', 'BLOCKQUOTE', 'CENTER', 'DD', 'DIV', 'DL', 'DT', 'FIGCAPTION',
            'FIGURE', 'FOOTER', 'FORM', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'HEADER', 'HR', 'LI', 'MAIN', 'NAV', 'OL', 'P', 'PRE',
            'SECTION', 'TABLE', 'TD', 'TH', 'TR', 'UL']);
          const skipped = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEXTAREA', 'TITLE', 'TEMPLATE']);
          const blockOf = (node) => {
            for (let e = node.parentElement; e && e !== root; e = e.parentElement) if (blocks.has(e.tagName)) return e;
            return root;
          };
          const nodes = [];
          let text = '', lastBlock = null;
          const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
            acceptNode: n => n.nodeType === 1 && skipped.has(n.tagName) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT });
          for (let n = walker.nextNode(); n; n = walker.nextNode()) {
            if (n.nodeType === 1) { if (n.tagName === 'BR') text += '\\u2029'; continue; }
            const block = blockOf(n);
            if (block !== lastBlock) { text += '\\u2029'; lastBlock = block; }
            nodes.push({ node: n, start: text.length });
            text += fold(n.data);
          }
          const wordCharacter = /[\\p{L}\\p{N}]/u;
          const found = [];
          for (const term of terms) {
            const words = fold(term.text).split(/\\s+/).filter(w => w).map(w => w.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&'));
            if (!words.length) continue;
            const pattern = new RegExp(words.join('\\\\s+'), 'g');
            for (let m; (m = pattern.exec(text)); ) {
              if (term.wordStart && m.index > 0 && wordCharacter.test(text[m.index - 1])) continue;
              found.push([m.index, m.index + m[0].length, term.group]);
            }
          }
          found.sort((a, b) => a[0] - b[0]);
          const merged = [], spaces = /^[^\\S\\u2029]*$/;
          for (const r of found) {
            const last = merged[merged.length - 1];
            if (last && (r[0] <= last[1] || (joinSpaced && last[2].has(r[2]) && spaces.test(text.slice(last[1], r[0]))))) {
              last[1] = Math.max(last[1], r[1]);
              last[2].add(r[2]);  // every row found in it, so two rows with the same words still mark them as one
            } else merged.push([r[0], r[1], new Set([r[2]])]);
          }
          // Last first, so the text nodes still to split keep their offsets.
          for (let r = merged.length - 1; r >= 0; r--) {
            const [a, b] = merged[r];
            let lo = 0, hi = nodes.length - 1, i = -1;
            while (lo <= hi) { const mid = (lo + hi) >> 1; if (nodes[mid].start < b) { i = mid; lo = mid + 1; } else hi = mid - 1; }
            for (; i >= 0; i--) {
              const { node, start } = nodes[i];
              const end = start + node.data.length;
              if (end <= a) break;
              const x = Math.max(a, start) - start, y = Math.min(b, end) - start;
              if (y <= x) continue;
              const part = x > 0 ? node.splitText(x) : node;
              if (y - x < part.data.length) part.splitText(y - x);
              const mark = document.createElement('mmj-mark');
              mark.dataset.n = r;
              part.replaceWith(mark);
              mark.appendChild(part);
            }
          }
          return merged.length;
        };
        """

    /// What the search marks in the message shown (headers and text), as MailMate highlights it.
    var highlights: [SearchHighlight] = [] {
        didSet {
            guard highlights != oldValue else { return }
            markAll(revealing: false)
        }
    }

    /// Marks, in the headers and the text, Find's matches while the find bar has text (each its own, the
    /// current one yellow), else the search's.
    private func markAll(revealing: Bool) {
        // The raw source has the headers in its text; the header view is hidden.
        header.mark(rawShown ? [] : findText.map { [SearchHighlight($0, wordStart: false)] } ?? highlights, finding: findText != nil)
        markText(revealing: revealing)
    }

    private func markText(revealing: Bool) {
        let terms = findText.map { [SearchHighlight($0, wordStart: false)] } ?? highlights
        shownWebView.callAsyncJavaScript(
            "return typeof mmjMark === 'function' ? mmjMark(terms, join) : -1;",
            arguments: ["terms": terms.map { ["text": $0.text, "wordStart": $0.wordStart, "group": $0.group] }, "join": findText == nil],
            in: nil, in: .defaultClient
        ) { [weak self] result in
            let marked = (try? result.get()) as? Int ?? 0
            #if DEBUG
                NSLog("MMJ marked: \(marked)")
            #endif
            guard let self, findText != nil else { return }
            textMatches = max(0, marked)
            showCurrentMatch(revealing: revealing)
        }
    }

    // MARK: Find (Edit ▸ Find)

    /// The find bar's text while it's open and has some.
    private var findText: String?
    /// Find's current match: the headers' first, in order, then the text's.
    private var findIndex = 0
    /// How many matches the page's text has (the headers count their own).
    private var textMatches = 0
    /// What had the keyboard before the find bar, which gets it back after Done.
    private weak var beforeFind: NSResponder?

    /// Over the message, which moves down under it (the scroll view's top, `scrollTop`).
    private let findBar = MessageFindBar()
    private var scrollTop: NSLayoutConstraint?

    var showsFindBar: Bool { !findBar.isHidden }

    /// What Tab focuses: the find bar's field (while it's shown), and the message.
    var findKeyView: NSView { findBar.field }
    var messageKeyView: NSView { shownWebView }

    /// Whether a message is shown (Find has something to look in).
    var showsMessage: Bool { currentID != nil }

    #if DEBUG
        /// The page's height as laid out, and scrolls to its end (for the raw source's last lines).
        func debugScrollToEnd() -> CGFloat {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            return document.frame.height
        }

        /// ⌘F, then `text` as typed in the bar.
        func debugFind(_ text: String) {
            showFind()
            findBar.field.stringValue = text
            find(text)
        }

        /// A remote-content bar button's action, as clicking it does.
        func debugBarAction(_ action: MessagePage.Action) { perform(action) }

        /// Escape in the find bar's field, logging what's left.
        func debugFindEscape() {
            findBar.escape()
            NSLog("MMJ find escape: bar \(findBar.isHidden ? "hidden" : "shown"), text \"\(findBar.field.stringValue)\", finding \(findText ?? "-")")
        }
    #endif

    /// Edit ▸ Find ▸ Find… (⌘F), as MailMate's: the find bar over the message, its text selected to type over.
    func showFind() {
        if findBar.isHidden {
            beforeFind = view.window?.firstResponder
            findBar.isHidden = false
            scrollTop?.constant = MessageFindBar.height
        }
        view.window?.makeFirstResponder(findBar.field)
        findBar.field.currentEditor()?.selectAll(nil)
        find(findBar.field.stringValue)
    }

    /// Done (or Escape): the bar goes, the search's marks come back, the keyboard goes back where it was.
    func hideFind() {
        guard !findBar.isHidden else { return }
        let hadKeyboard = findBar.field.currentEditor() != nil
        findBar.isHidden = true
        scrollTop?.constant = 0
        find("")
        // Back to what had it, if it's still in the window (a view, or a field's editor).
        let back = (beforeFind as? NSView).flatMap { $0.window === view.window ? $0 : nil } ?? shownWebView
        if hadKeyboard { view.window?.makeFirstResponder(back) }
    }

    /// Find Next (⌘G) and Find Previous (⇧⌘G), or ‹ › and Return: the match after (before) the current
    /// one, round to the first (last), brought into view.
    func findNext(forward: Bool) {
        if findBar.isHidden { showFind() }
        let total = header.markCount + textMatches
        guard total > 0 else { return NSSound.beep() }
        findIndex = (findIndex + (forward ? 1 : total - 1)) % total
        showCurrentMatch(revealing: true)
    }

    /// Use Selection for Find (⌘E): the text selected in the message, as the text to find.
    func useSelectionForFind() {
        func use(_ text: String) {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return NSSound.beep() }
            findBar.field.stringValue = text
            findBar.rememberText()
            if !findBar.isHidden { find(text) }
        }
        // A header value's selection (its field editor), else the page's.
        if let editor = view.window?.firstResponder as? NSTextView, editor.isFieldEditor,
            (editor.delegate as? NSView)?.isDescendant(of: header) == true
        {
            return use((editor.string as NSString).substring(with: editor.selectedRange()))
        }
        shownWebView.callAsyncJavaScript("return window.getSelection().toString();", arguments: [:], in: nil, in: .defaultClient) { result in
            use((try? result.get()) as? String ?? "")
        }
    }

    /// Finds `text` anew (the first match current); "" leaves the search's marks.
    private func find(_ text: String) {
        let text: String? = text.isEmpty ? nil : text
        guard text != findText else { return }
        (findText, findIndex) = (text, 0)
        findBar.showCount(nil)
        if text == nil { header.currentMark = nil }
        markAll(revealing: true)
    }

    /// Shows how many matches there are and makes the current one yellow, bringing it into view.
    private func showCurrentMatch(revealing: Bool) {
        guard findText != nil else { return findBar.showCount(nil) }
        let total = header.markCount + textMatches
        findBar.showCount(total)
        findIndex = total == 0 ? 0 : min(findIndex, total - 1)
        let inHeader = total > 0 && findIndex < header.markCount
        header.currentMark = inHeader ? findIndex : nil
        if inHeader, revealing, let rect = header.markRect(findIndex) { reveal(header.convert(rect, to: document)) }
        let inText = total > 0 && !inHeader ? findIndex - header.markCount : -1
        let page = shownWebView
        page.callAsyncJavaScript(
            "return typeof mmjCurrent === 'function' ? mmjCurrent(n) : null;", arguments: ["n": inText], in: nil, in: .defaultClient
        ) { [weak self] result in
            guard let self, revealing, inText >= 0, let edges = (try? result.get()) as? [Double], edges.count == 2 else { return }
            let scale = page.magnification
            reveal(NSRect(x: 0, y: page.frame.minY + edges[0] * scale, width: 1, height: (edges[1] - edges[0]) * scale))
        }
    }

    /// Scrolls the message so `rect` (in the document) shows, centred if it was out of view.
    private func reveal(_ rect: NSRect) {
        let visible = scroll.contentView.bounds
        guard rect.minY < visible.minY || rect.maxY > visible.maxY else { return }
        let y = min(max(rect.midY - visible.height / 2, 0), max(0, document.frame.height - visible.height))
        scroll.contentView.scroll(to: NSPoint(x: visible.minX, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            if let height = (message.body as? NSNumber)?.doubleValue { contentHeightChanged(height, of: message.webView) }
        }
    }

    /// Points: the page measures in CSS pixels, which zooming scales. Capped against a page that grows
    /// with its own view (`min-height: 120vh`); the raw source's own page doesn't, and runs long (a big
    /// attachment's base64 is thousands of lines).
    private func contentHeightChanged(_ height: Double, of page: WKWebView? = nil) {
        if page === rawView {
            rawHeight = min(CGFloat(height) * rawView.magnification, 10_000_000)
            return layoutDocument()
        }
        let points = min(CGFloat(height) * webView.magnification, 200_000)
        guard points != contentHeight else { return }
        contentHeight = points
        layoutDocument()
    }

    /// Measures the content once more when the page has loaded (the script reports changes after that),
    /// and marks what the search finds in it.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === rawView { return rawPageLoaded() }
        if !highlights.isEmpty || findText != nil { markText(revealing: false) }
        if let bar = shownBar, bar.loaded { countDownloadedPixels(bar) }
        webView.callAsyncJavaScript(
            "const e = document.querySelector('mmj-end'); return e ? Math.ceil(e.getBoundingClientRect().top + window.scrollY) : 0;",
            arguments: [:], in: nil, in: .defaultClient
        ) { [weak self] result in
            if let height = (try? result.get()) as? Double, height > 0 { self?.contentHeightChanged(height, of: webView) }
        }
    }

    @objc private func clipResized() { layoutDocument() }

    /// The header on top, the content under it, as tall as the content (and at least down to the
    /// pane's bottom, so the page's background fills it); the raw source alone, the same way.
    private func layoutDocument() {
        let width = scroll.contentView.bounds.width, visible = scroll.contentView.bounds.height
        if rawShown {
            rawView.frame = NSRect(x: 0, y: 0, width: width, height: max(rawHeight, visible))
            document.frame = rawView.frame
            return
        }
        let headerHeight = header.height(forWidth: width)
        let webHeight = max(contentHeight, visible - headerHeight)
        header.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight)
        webView.frame = NSRect(x: 0, y: headerHeight, width: width, height: webHeight)
        document.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight + webHeight)
        // Under them while it loads, already at its size: changing places redraws nothing.
        rawView.frame = NSRect(x: 0, y: 0, width: width, height: max(rawHeight, visible))
    }

    func show(messageID: Int64?, selectionCount: Int = 1) {
        guard let messageID else {
            currentID = nil
            showPlaceholder(selectionCount > 1 ? "\(selectionCount) Messages Selected" : "No Message Selected")
            return
        }
        guard messageID != currentID else { return }
        if messageID != rawID { endRaw() }  // another message shows formatted, as in MailMate
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
        endRaw()
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
            .init(label: "Date:", value: Formatters.fullDate(detail.sentAt ?? detail.receivedAt), searched: false),
            .init(label: "To:", value: list(.to, groups: .toGroup)),
            .init(label: "Cc:", value: list(.cc, groups: .ccGroup)),
            .init(label: "Bcc:", value: list(.bcc)),
        ]
    }

    private func showStatus(_ text: String) {
        guard !rawShown else { return }  // the body's loading doesn't cover the source
        renderGeneration += 1  // a page still being prepared doesn't show over this
        attachments = []
        applyRules(loadRemote: false)
        loadPage(content: "<p class=\"status\">\(MessagePage.escape(text))</p>", bar: nil, plain: false, remote: false)
    }

    /// Bumped by each render: a page prepared in the background shows only if no render came after it.
    private var renderGeneration = 0

    private func render(_ body: MessageBody) {
        if rawShown { return (currentBody, formattedStale) = (body, true) }  // shown with Show Formatted Message
        renderGeneration += 1
        // The window comes up while the rules are compiled: a message waits for them (nothing would
        // block its remote content yet).
        if let preparing = Self.preparingRules {
            #if DEBUG
                launchLog("message waits for block rules")
            #endif
            let generation = renderGeneration
            Task {
                await preparing.value
                guard generation == renderGeneration else { return }
                render(body)
            }
            return
        }
        currentBody = body
        attachments = currentID.map { Self.attachments(messageId: $0, html: body.html, store: model.store) } ?? []
        guard let html = body.html, let id = currentID else {
            applyRules(loadRemote: false)
            loadPage(content: MessagePage.plainHTML(body.text ?? ""), bar: nil, plain: true, remote: false)
            return
        }
        #if DEBUG
            launchLog("message rendered, rules \(Self.blockAllRules != nil && Self.strictRules != nil && Self.scriptRules != nil ? "ready" : "missing")")
        #endif
        // Fail closed: remote content only loads when the strict and script rules are in place.
        let loadRemote = loadRemoteForCurrent && Self.strictRules != nil && Self.scriptRules != nil
        func show(_ prepared: PreparedHTML, page: String) {
            let bar = prepared.remoteCount == 0 ? nil : MessagePage.Bar(resources: prepared.resources, loaded: loadRemote)
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

    // MARK: Raw source

    /// The message whose raw source was asked for (View ▸ Show Raw Message). It shows in place of the
    /// message, headers and all, until the item is chosen again or another message shows, as in MailMate.
    private var rawID: Int64?
    var showsRaw: Bool { rawID != nil && rawID == currentID }
    /// The source is on screen: its page drew under the message's, then they changed places.
    private var rawShown = false
    /// A body came while the source showed: Show Formatted Message draws it.
    private var formattedStale = false
    /// Raw pages asked for: one that's been replaced or given up doesn't show.
    private var rawLoads = 0

    /// View ▸ Show Raw Message, or Show Formatted Message while the source shows. The message stays
    /// on screen, untouched, until the source has drawn; going back shows it again at once.
    func toggleRawMessage() {
        guard let id = displayedMessageID else { return }
        if showsRaw {
            let stale = formattedStale
            endRaw()
            if stale, let currentBody { render(currentBody) }
            return
        }
        rawID = id
        rawLoads += 1
        let load = rawLoads
        Task {
            do {
                let source = try await model.rawMessage(messageId: id)
                let page = await Task.detached(priority: .userInitiated) { MessagePage.rawHTML(source) }.value
                guard load == rawLoads, showsRaw else { return }
                rawHeight = 0
                rawView.isHidden = false
                layoutDocument()
                rawView.loadHTMLString(page, baseURL: nil)
            } catch {
                guard load == rawLoads, showsRaw else { return }
                rawID = nil
                let alert = NSAlert()
                alert.messageText = "Couldn’t show the raw message."
                alert.informativeText = AppModel.describe(error)
                if let window = view.window { alert.beginSheetModal(for: window) { _ in } } else { alert.runModal() }
            }
        }
    }

    /// The source's page has loaded under the message: once it has drawn (a snapshot waits for that),
    /// the two change places. Its height comes as the page reports it.
    private func rawPageLoaded() {
        let load = rawLoads
        guard showsRaw else { return }
        let drawn = WKSnapshotConfiguration()
        drawn.rect = NSRect(x: 0, y: 0, width: rawView.bounds.width, height: scroll.contentView.bounds.height)
        rawView.takeSnapshot(with: drawn) { [weak self] _, _ in
            guard let self, load == rawLoads, showsRaw, !rawShown else { return }
            rawShown = true
            header.isHidden = true
            webView.isHidden = true
            layoutDocument()
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            if !highlights.isEmpty || findText != nil { markAll(revealing: false) }
        }
    }

    /// The message again in place of its source (or none asked for any more), as it was.
    private func endRaw() {
        guard rawID != nil || rawShown else { return }
        let wasShown = rawShown
        (rawID, rawShown, formattedStale) = (nil, false, false)
        rawLoads += 1
        header.isHidden = false
        webView.isHidden = false
        rawView.isHidden = true
        rawView.loadHTMLString("", baseURL: nil)
        layoutDocument()
        guard wasShown else { return }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        if !highlights.isEmpty || findText != nil { markAll(revealing: false) }
    }

    private func loadPage(content: String, bar: MessagePage.Bar?, plain: Bool, remote: Bool) {
        loadPage(MessagePage.html(content: content, plain: plain, remote: remote), bar: bar)
    }

    private func loadPage(_ html: String, bar: MessagePage.Bar?) {
        webView.resetHover()
        shownBar = bar
        header.update(fields: headerFields, attachments: attachments.map(Self.headerAttachment), bar: bar)
        (textMatches, findIndex) = (0, 0)  // the text's are counted when the page has loaded
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

    /// Compiles the content-rule lists, in the background: call once at launch. Messages shown before
    /// they're ready wait for them.
    static func prepareBlockRules() {
        preparingRules = Task {
            #if DEBUG
                if let seconds = Double(ProcessInfo.processInfo.environment["MMJ_DEBUG_SLOW_RULES"] ?? "") {
                    try? await Task.sleep(for: .seconds(seconds))  // as if compiling took that long
                }
            #endif
            await compileBlockRules()
            preparingRules = nil
            launchLog("block rules compiled")
        }
    }

    /// The rules being compiled, until they're ready.
    private static var preparingRules: Task<Void, Never>?

    private static func compileBlockRules() async {
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
    private func withAttachmentFile(_ index: Int, _ body: @escaping @MainActor (URL) async -> Void) {
        guard attachments.indices.contains(index), let id = currentID, let detail = currentDetail else { return }
        let part = attachments[index]
        Task { @MainActor in
            do {
                let url = try await model.attachmentFile(messageId: id, index: index, accountId: detail.accountId, part: part)
                await body(url)
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
    private func withAllAttachmentFiles(_ body: @escaping @MainActor ([URL]) async -> Void) {
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
            await body(urls)
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
                    guard let self, await self.copy(source, to: target, replacing: false) else { return }
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
            self?.withAttachmentFile(index) { source in await self?.copy(source, to: target, replacing: true) }
        }
    }

    /// Saves into ~/Downloads without asking, as MailMate's download button does, and bounces the
    /// Downloads stack in the Dock as browsers do.
    private func saveAttachmentToDownloads(_ index: Int) {
        withAttachmentFile(index) { [weak self] source in
            guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
            let target = Self.unusedURL(downloads.appendingPathComponent(source.lastPathComponent))
            if let self, await self.copy(source, to: target, replacing: false) {
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

    /// Copies an attachment's file where it's saved (off the main thread: another disk copies it whole).
    @discardableResult
    private func copy(_ source: URL, to target: URL, replacing: Bool) async -> Bool {
        do {
            try await AppModel.offMain {
                if replacing && FileManager.default.fileExists(atPath: target.path) {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: Self.stagedCopy(of: source))
                } else {
                    try FileManager.default.copyItem(at: source, to: target)
                }
                try AppModel.quarantine(target)
            }
            return true
        } catch {
            let alert = NSAlert(error: error)
            if let window = view.window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            return false
        }
    }

    /// A copy of `source` beside it, for replacing a file in one step.
    nonisolated private static func stagedCopy(of source: URL) throws -> URL {
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

    /// The remote-content bar shown with the page.
    private var shownBar: MessagePage.Bar?

    /// Once loaded, the images that turned out 1 by 1 pixel: MailMate's red bar ("An image with a pixel
    /// size of 1 by 1 has been downloaded").
    private func countDownloadedPixels(_ bar: MessagePage.Bar) {
        webView.callAsyncJavaScript(
            """
            return [...document.images].filter(i => i.complete && i.naturalWidth === 1 && i.naturalHeight === 1
              && /^(https?|ftp):/i.test(i.currentSrc || i.src)).length;
            """, arguments: [:], in: nil, in: .defaultClient
        ) { [weak self] result in
            guard let self, let count = (try? result.get()) as? Int, count > 0, shownBar == bar else { return }
            var downloaded = bar
            downloaded.downloadedPixels = count
            shownBar = downloaded
            header.setBar(downloaded)
            layoutDocument()
        }
    }

    private func perform(_ action: MessagePage.Action, from button: NSView? = nil) {
        switch action {
        case .load:
            loadRemoteForCurrent = true
            rerender()
        case .reload:
            // The message as it first showed: its external resources blocked again.
            loadRemoteForCurrent = false
            rerender()
        }
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

        /// Gets the shown message's first attachment as a file, as Open and Quick Look do (twice: the
        /// second from the copy kept here), logging how long each took and the longest the main thread
        /// couldn't run meanwhile (a 2 ms timer on it).
        func debugTimeAttachment() async {
            guard let id = currentID, let detail = currentDetail, let part = attachments.first else {
                return NSLog("MMJ attachment timing: no attachment")
            }
            final class Beat: @unchecked Sendable {
                var last = ContinuousClock.now
                var longest: Duration = .zero
            }
            for round in ["first", "again"] {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Attachments/\(id)-0", isDirectory: true)
                try? FileManager.default.removeItem(at: folder)  // made anew, as for another message
                let beat = Beat()
                beat.last = .now
                let timer = Timer.scheduledTimer(withTimeInterval: 0.002, repeats: true) { _ in
                    let now = ContinuousClock.now
                    beat.longest = max(beat.longest, now - beat.last)
                    beat.last = now
                }
                let start = ContinuousClock.now
                let url = try? await model.attachmentFile(messageId: id, index: 0, accountId: detail.accountId, part: part)
                let took = start.duration(to: .now)
                timer.invalidate()
                beat.longest = max(beat.longest, beat.last.duration(to: .now))  // up to now, if it never ran
                let size = (try? url?.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                NSLog("MMJ attachment timing \(round): \(size / 1_000_000) MB in \(took), main thread held up to \(beat.longest)")
            }
        }
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
                try await AppModel.offMain {
                    try FileManager.default.copyItem(at: source, to: url)
                    try AppModel.quarantine(url)
                }
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
