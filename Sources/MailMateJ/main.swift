import AppKit
import JMAPKit
import MailSync

/// "MailMateJ" for release builds, "MailMateJ Dev" for debug builds (set by scripts/bundle.sh).
let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "MailMateJ"

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        #if DEBUG
            // MMJ_APPEARANCE=light|dark: the app in that appearance, whatever the system's.
            if let name = ProcessInfo.processInfo.environment["MMJ_APPEARANCE"] {
                NSApp.appearance = NSAppearance(named: name == "light" ? .aqua : .darkAqua)
            }
        #endif
        do {
            try AppModel.bootstrap()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "\(appName) could not open its mail database."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        Task {
            await MessageViewController.prepareBlockRules()
            AppModel.shared.start()
            let controller = MainWindowController(model: AppModel.shared)
            windowController = controller
            controller.showWindow(nil)
            NSApp.activate()
            #if DEBUG
                scheduleDebugSnapshot()
            #endif
        }
    }

    #if DEBUG
        /// `MMJ_SNAPSHOT=/path/shot.png` writes an image of the main window a few seconds after launch,
        /// for checking the UI from scripts without Screen Recording permission.
        private func scheduleDebugSnapshot() {
            guard let path = ProcessInfo.processInfo.environment["MMJ_SNAPSHOT"] else { return }
            Task {
                try? await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["MMJ_SNAPSHOT_DELAY"] ?? "4") ?? 4))
                if let key = ProcessInfo.processInfo.environment["MMJ_DEBUG_DUPLICATE"] {
                    windowController?.debugDuplicateSidebar(key)
                    try? await Task.sleep(for: .milliseconds(500))
                }
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_PROGRESS"] != nil {
                    windowController?.debugShowProgress()
                    try? await Task.sleep(for: .milliseconds(700))
                }
                if let column = ProcessInfo.processInfo.environment["MMJ_DEBUG_SORT"] {
                    windowController?.debugSort(column: column)  // as a click on its header
                    try? await Task.sleep(for: .seconds(1))
                }
                if let spec = ProcessInfo.processInfo.environment["MMJ_DEBUG_EMPTY"] {
                    // "<sidebar keys>[|erase|read]": logs their Mark All Read and Empty items; erase or read
                    // does that one as its menu item does.
                    let parts = spec.split(separator: "|").map(String.init)
                    for key in parts[0].split(separator: ",").map(String.init) {
                        windowController?.debugEmpty(key: key, choose: parts.count > 1 ? parts[1] : nil)
                    }
                    try? await Task.sleep(for: .seconds(4))
                }
                if let spec = ProcessInfo.processInfo.environment["MMJ_DEBUG_FLAGS"] {
                    // "<account id>|<subject>|<step>,…" on the account's message with that subject: answer,
                    // unanswer, forward, unforward (as replying or forwarding marks it), ext+answered,
                    // ext-answered, ext+forwarded, ext-forwarded (the IMAP flag set elsewhere, not here),
                    // check (the flag check), scratch (a first flag check again), read (toggled in Gmail
                    // through its API, twice), report, wait=<seconds>.
                    let parts = spec.split(separator: "|").map(String.init)
                    let id = parts[0], model: AppModel = AppModel.shared
                    guard let messageId = ((try? model.store.messageIDs(scope: .account(id))) ?? []).first(where: { (try? model.store.detail(id: $0))?.subject == parts[1] }),
                        let ref = (try? model.store.refs(ids: [messageId]))?.first
                    else { return NSLog("MMJ flags: no message “\(parts[1])”") }
                    for step in parts[2].split(separator: ",").map(String.init) {
                        do {
                            switch step {
                            case "answer", "unanswer", "forward", "unforward":
                                let keyword = step.hasSuffix("answer") ? "$answered" : "$forwarded", on = !step.hasPrefix("un")
                                try model.store.setKeyword(keyword, on, messageIds: [messageId])
                                try await model.coordinatorForDebug.update(
                                    accountId: id, remoteIds: [ref.remoteId], patch: ["keywords/\(keyword)": on ? .bool(true) : .null])
                            case let ext where ext.hasPrefix("ext"):
                                let flag = ext.hasSuffix("answered") ? "\\Answered" : "$Forwarded"
                                try await model.coordinatorForDebug.debugGmailStoreFlag(accountId: id, remoteId: ref.remoteId, flag: flag, add: ext.hasPrefix("ext+"))
                            case "check", "scratch":
                                try await model.coordinatorForDebug.debugGmailFlags(accountId: id, fromScratch: step == "scratch")
                            case "read":
                                await model.debugRemoteReadChange(accountId: id, subject: parts[1])
                            case "imapflags":  // all of them, as Gmail's IMAP has them
                                NSLog("MMJ flags \(ref.remoteId) in IMAP: \(try await model.coordinatorForDebug.debugGmailIMAPFlags(accountId: id, remoteId: ref.remoteId).map { $0.sorted() })")
                            case "report":
                                NSLog("MMJ flags \(ref.remoteId): \((try? model.store.keywords(messageId: messageId))?.sorted() ?? [])")
                            case let wait where wait.hasPrefix("wait="):
                                try? await Task.sleep(for: .seconds(Double(wait.dropFirst(5)) ?? 1))
                            default: NSLog("MMJ flags: no step \(step)")
                            }
                        } catch {
                            NSLog("MMJ flags \(step): \(error)")
                        }
                    }
                }
                if let spec = ProcessInfo.processInfo.environment["MMJ_DEBUG_COMPOSE"] {
                    // "<account id>|<step>,…", as the compose window does: identities (logs them), draft (saves a
                    // test draft to the account's own address, replacing the last), load (reopens it), discard,
                    // reply (reply headers for the Inbox's newest message), send (sends the test message to the
                    // account's own address), wait=<seconds>.
                    let parts = spec.split(separator: "|").map(String.init)
                    let id = parts[0]
                    let model: AppModel = AppModel.shared
                    var last: AppModel.DraftRef?
                    func test(_ round: Int) -> (OutgoingMessage, String)? {
                        guard let identity = (try? model.store.identities())?.first(where: { $0.accountId == id }) else { return nil }
                        var message = OutgoingMessage(
                            identityId: identity.remoteId, from: EmailAddress(name: identity.name, email: identity.email),
                            to: [EmailAddress(name: "Tëst Sëlf", email: identity.email)], cc: [], bcc: [],
                            subject: "MailMateJ test \(round) — café ✓", text: "Hello **there**, round \(round).\n\n![](cid:dot1)\n")
                        message.html = "<p>Hello <strong>there</strong>, round \(round).</p><p><img src=\"cid:dot1\"></p>"
                        message.draftFormat = "markdown"
                        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
                        message.files = [
                            OutgoingFile(name: "dot.png", type: "image/png", data: png, cid: "dot1"),
                            OutgoingFile(name: "Résumé ✓.txt", type: "text/plain", data: Data("attached text\n".utf8)),
                        ]
                        return (message, identity.email)
                    }
                    var round = 0
                    for step in parts[1].split(separator: ",").map(String.init) {
                        do {
                            switch step {
                            case "drafts":  // as Gmail lists them
                                NSLog("MMJ compose drafts in Gmail: \(try await model.coordinatorForDebug.debugGmailDrafts(accountId: id))")
                            case "identities":
                                NSLog("MMJ compose identities: \(((try? model.store.identities()) ?? []).filter { $0.accountId == id }.map { "\($0.name) <\($0.email)> \($0.remoteId)" })")
                            case "draft":
                                round += 1
                                guard let (message, _) = test(round) else { NSLog("MMJ compose: no identity"); continue }
                                let ref = try await model.saveDraft(message, accountId: id, replacing: last.map { [$0] } ?? [])
                                NSLog("MMJ compose draft \(round): saved \(ref.remoteId), replacing \(last?.remoteId ?? "-")")
                                last = ref
                            case "load":
                                guard let last else { continue }
                                let draft = try await model.coordinatorForDebug.loadDraft(accountId: id, remoteId: last.remoteId)
                                NSLog("MMJ compose load: from=\(draft.from ?? "-") to=\(draft.to.map { "\($0.name ?? "") <\($0.email ?? "")>" }) subject=\(draft.subject) markdown=\(draft.isMarkdown) text=\(draft.text.debugDescription) attachments=\(draft.attachments.map { "\($0.name ?? "-") \($0.type) cid=\($0.cid ?? "-")" })")
                            case let discard where discard.hasPrefix("discard="):  // a draft by its message id
                                model.discardDrafts([AppModel.DraftRef(accountId: id, remoteId: String(discard.dropFirst(8)))])
                                NSLog("MMJ compose discard: \(discard.dropFirst(8))")
                            case "discard":
                                if let last { model.discardDrafts([last]) }
                                NSLog("MMJ compose discard: \(last?.remoteId ?? "-")")
                                last = nil
                            case "reply":
                                guard let inbox = try model.store.mailbox(accountId: id, role: "inbox"),
                                    let newest = try model.store.messageIDs(scope: .mailbox(inbox.id)).first,
                                    let ref = try model.store.refs(ids: [newest]).first
                                else { continue }
                                let headers = try await model.coordinatorForDebug.replyHeaders(accountId: id, remoteId: ref.remoteId)
                                NSLog("MMJ compose reply headers: inReplyTo=\(headers.inReplyTo) references=\(headers.references)")
                            case "replydraft":  // a draft replying to the Inbox's newest message (Gmail should thread it there)
                                guard let inbox = try model.store.mailbox(accountId: id, role: "inbox"),
                                    let newest = try model.store.messageIDs(scope: .mailbox(inbox.id)).first,
                                    let ref = try model.store.refs(ids: [newest]).first, let detail = try model.store.detail(id: newest),
                                    var (message, _) = test(0)
                                else { continue }
                                (message.inReplyTo, message.references) = try await model.coordinatorForDebug.replyHeaders(accountId: id, remoteId: ref.remoteId)
                                message.subject = Compose.replySubject(detail.subject)
                                let saved = try await model.saveDraft(message, accountId: id, replacing: [])
                                last = saved
                                NSLog("MMJ compose reply draft: saved \(saved.remoteId) replying to \(ref.remoteId) “\(detail.subject)”")
                            case "send":
                                round += 1
                                guard let (message, _) = test(round) else { continue }
                                try await model.send(message, accountId: id, original: nil)
                                NSLog("MMJ compose send: sent")
                            case let wait where wait.hasPrefix("wait="):
                                try? await Task.sleep(for: .seconds(Double(wait.dropFirst(5)) ?? 1))
                            default: NSLog("MMJ compose: no step \(step)")
                            }
                        } catch {
                            NSLog("MMJ compose \(step): \(error)")
                        }
                    }
                }
                if let spec = ProcessInfo.processInfo.environment["MMJ_DEBUG_OFFLINE"] {
                    // "<account id>|<step>,…": offline (Take Offline), select (its row), drop (Google drops its
                    // sign-in quietly), takeonline (Take Online), fetch (its first message), expire (Google refuses its sign-in),
                    // online (Take Online, as after Google's page), flag (toggles the flag of its Inbox's
                    // first message), report (how it stands, its menus), snap (the main window, captured
                    // as <MMJ_SNAPSHOT>-<n>.png), wait=<seconds>.
                    let parts = spec.split(separator: "|").map(String.init)
                    let id = parts[0]
                    let model: AppModel = AppModel.shared
                    let inbox = (try? model.store.mailbox(accountId: id, role: "inbox")).flatMap { $0 }.map { "mailbox.\(id).\($0.remoteId)" } ?? ""
                    var shot = 0
                    for step in parts[1].split(separator: ",").map(String.init) {
                        switch step {
                        case "offline": model.takeOffline(accountId: id)
                        case "drop": AppModel.debugExpiredSignIn = id  // Google drops its sign-in, nothing told
                        case "takeonline":  // as Take Online does
                            do {
                                try await model.takeOnline(accountId: id)
                                NSLog("MMJ offline take online: done")
                            } catch {
                                NSLog("MMJ offline take online: \(error)")
                            }
                        case "fetch": await model.debugFetch(accountId: id)
                        case "select":  // the account's row, the sidebar focused (the accent selection)
                            windowController?.debugSelectSidebar(key: "account.\(id)")
                            windowController?.debugFocusSidebar()
                        case "expire": await model.debugRestartSignIn(accountId: id, expired: true)
                        case "online": await model.debugRestartSignIn(accountId: id, expired: false)
                        case "flag":
                            windowController?.debugSelectSidebar(key: inbox)
                            try? await Task.sleep(for: .seconds(2))
                            windowController?.debugSelectNextMessage()
                            try? await Task.sleep(for: .seconds(1))
                            windowController?.debugPerform("flag")
                        case "report":
                            let status = model.statuses[id]
                            NSLog("MMJ offline: offline=\(model.isOffline(accountId: id)) needsSignIn=\(model.needsSignIn(accountId: id)) queued=\(status?.queuedChanges ?? -1) phase=\(status.map { "\($0.phase)" } ?? "-") reason=\(model.offlineReason(accountId: id)?.replacingOccurrences(of: "\n", with: " / ") ?? "-") warning=\(model.syncWarning(accountId: id)?.split(separator: "\n").first ?? "-")")
                            NSLog("MMJ offline menu: \(windowController?.debugSidebarContextMenu(key: "account.\(id)").suffix(3).joined(separator: " | ") ?? "")")
                            NSLog("MMJ offline inbox menu: \(windowController?.debugSidebarContextMenu(key: inbox).suffix(3).joined(separator: " | ") ?? "")")
                        case "snap":
                            shot += 1
                            if let number = windowController?.window?.windowNumber {
                                let capture = Process()
                                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                                capture.arguments = ["-x", "-o", "-l\(number)", path.replacingOccurrences(of: ".png", with: "-\(shot).png")]
                                try? capture.run()
                                capture.waitUntilExit()
                            }
                        case let wait where wait.hasPrefix("wait="):
                            try? await Task.sleep(for: .seconds(Double(wait.dropFirst(5)) ?? 1))
                        default: NSLog("MMJ offline: no step \(step)")
                        }
                    }
                }
                if let keys = ProcessInfo.processInfo.environment["MMJ_DEBUG_SIDEBAR_MENU"] {
                    for key in keys.split(separator: ",").map(String.init) {  // logs each mailbox's context menu
                        NSLog("MMJ sidebar menu \(key): \(windowController?.debugSidebarContextMenu(key: key).joined(separator: " | ") ?? "")")
                    }
                }
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_BADGES"] != nil {
                    NSLog("MMJ badges: \(windowController?.debugSidebarBadges ?? "")")
                }
                if let spec = ProcessInfo.processInfo.environment["MMJ_DEBUG_SIDEBAR_MOVE"] {
                    windowController?.debugMoveSidebar(spec)
                    try? await Task.sleep(for: .milliseconds(500))
                }
                if let key = ProcessInfo.processInfo.environment["MMJ_DEBUG_COLOR_MENU"] {
                    windowController?.debugCaptureColorMenu(key: key, path: path.replacingOccurrences(of: ".png", with: "-colors.png"))
                }
                if let key = ProcessInfo.processInfo.environment["MMJ_DEBUG_SYMBOL_MENU"] {
                    windowController?.debugSymbolMenu(key: key, path: path.replacingOccurrences(of: ".png", with: "-symbols.png"))
                }
                if let key = ProcessInfo.processInfo.environment["MMJ_DEBUG_NEW_SMART_IN"] {
                    windowController?.debugNewSmartMailbox(inside: key)  // as its New Smart Mailbox does
                    try? await Task.sleep(for: .seconds(1))
                }
                if let key = ProcessInfo.processInfo.environment["MMJ_DEBUG_SELECT"] {
                    windowController?.debugSelectSidebar(key: key)  // e.g. account.dev-carol
                    try? await Task.sleep(for: .seconds(1))
                }
                if let id = Int64(ProcessInfo.processInfo.environment["MMJ_DEBUG_DELETE_SMART"] ?? "") {
                    try? await Task.sleep(for: .seconds(1))
                    AppModel.shared.deleteSmartMailbox(id: id)  // as Delete Mailbox does
                    try? await Task.sleep(for: .seconds(1))
                }
                NSLog("MMJ inbox badge before: \(windowController?.debugInboxBadge ?? -1)")
                if let steps = Int(ProcessInfo.processInfo.environment["MMJ_SNAPSHOT_STEPS"] ?? "") {
                    for _ in 0..<steps {
                        windowController?.debugSelectNextMessage()
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                }
                if let row = Int(ProcessInfo.processInfo.environment["MMJ_SNAPSHOT_SELECT_ROW"] ?? "") {
                    windowController?.debugSelectRow(row)
                    try? await Task.sleep(for: .milliseconds(400))
                }
                // MMJ_SNAPSHOT_ROUNDTRIP=<sidebar key>: switch to that mailbox and back before the snapshot.
                if let row = Int(ProcessInfo.processInfo.environment["MMJ_SNAPSHOT_CORR_ROW"] ?? "") {
                    try? await Task.sleep(for: .milliseconds(600))
                    windowController?.debugSelectCorrespondence(row: row)
                    try? await Task.sleep(for: .milliseconds(600))
                }
                if let subject = ProcessInfo.processInfo.environment["MMJ_DEBUG_SELECT_SUBJECT"] {
                    windowController?.debugSelect(subject: subject)
                    try? await Task.sleep(for: .seconds(2))
                }
                if let path = ProcessInfo.processInfo.environment["MMJ_DEBUG_SWATCHES"] {
                    // The Color menu's swatches at 1x on the dark menu background, side by side.
                    let images = [
                        MailboxColors.swatch { .controlAccentColor }, MailboxColors.swatch { .labelColor },
                        MailboxColors.multicolorSwatch, MailboxColors.customSwatch, MailboxColors.swatch { .systemRed },
                        MailboxColors.swatch { .systemGreen },
                    ]
                    let rep = NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: 20 * images.count, pixelsHigh: 17, bitsPerSample: 8, samplesPerPixel: 4,
                        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                        NSColor(srgbRed: 0.21, green: 0.23, blue: 0.24, alpha: 1).setFill()
                        NSRect(x: 0, y: 0, width: 20 * images.count, height: 17).fill()
                        for (i, image) in images.enumerated() { image.draw(at: NSPoint(x: i * 20 + 2, y: 2), from: .zero, operation: .sourceOver, fraction: 1) }
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                if let role = ProcessInfo.processInfo.environment["MMJ_DEBUG_COPY_ROW0"] {
                    windowController?.debugCopy(row: 0, role: role)  // the first row's message into that mailbox too
                    try? await Task.sleep(for: .seconds(3))
                    NSLog("MMJ source: \(windowController?.debugSource(row: 0) ?? "-")")
                }
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_MAILBOX_MENUBAR"] != nil,
                    let menu = NSApp.mainMenu?.item(withTitle: "Mailbox")?.submenu
                {
                    menu.delegate?.menuNeedsUpdate?(menu)  // as opening it does
                    // Validated by the main window, as when it's key (a snapshot run's window isn't).
                    for item in menu.items {
                        if let action = item.action, let controller = windowController, controller.responds(to: action) {
                            item.isEnabled = controller.validateMenuItem(item)
                        }
                    }
                    NSLog("MMJ Mailbox menu: \(menu.items.map { $0.isSeparatorItem ? "—" : $0.title + ($0.isEnabled && ($0.action != nil || $0.submenu != nil) ? "" : " (off)") })")
                }
                if let path = ProcessInfo.processInfo.environment["MMJ_DEBUG_MENU_ICONS"] {
                    // The mailbox menu's first items (icon and title) drawn to `path`, with Inbox given a red
                    // star for the run (then put back).
                    MailboxSymbols.set("star", for: "unified.inbox")
                    MailboxColors.set(.system("red"), for: "unified.inbox")
                    let menu = MailboxMenu().build(roots: SidebarViewController.currentTree(model: AppModel.shared), selection: "")
                    let items = menu.items.filter { $0.image != nil }.prefix(8)
                    let image = NSImage(size: NSSize(width: 220, height: CGFloat(items.count) * 22), flipped: true) { _ in
                        NSColor.windowBackgroundColor.setFill()
                        NSRect(x: 0, y: 0, width: 220, height: CGFloat(items.count) * 22).fill()
                        for (i, item) in items.enumerated() {
                            item.image?.draw(in: NSRect(x: 6, y: CGFloat(i) * 22 + 3, width: item.image!.size.width, height: item.image!.size.height))
                            (item.title as NSString).draw(at: NSPoint(x: 32, y: CGFloat(i) * 22 + 3),
                                                          withAttributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
                        }
                        return true
                    }
                    if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                    }
                    MailboxSymbols.set(nil, for: "unified.inbox")
                    var colors = UserDefaults.standard.dictionary(forKey: "MailboxColors") ?? [:]
                    colors["unified.inbox"] = nil
                    UserDefaults.standard.set(colors, forKey: "MailboxColors")
                }
                if let steps = ProcessInfo.processInfo.environment["MMJ_DEBUG_SEARCH"] {
                    // Searches, ";"-separated ("" clears), logging the list after each.
                    for text in steps.split(separator: ";", omittingEmptySubsequences: false) {
                        windowController?.debugSearch(String(text))
                        try? await Task.sleep(for: .seconds(2))
                        NSLog("MMJ search \"\(text)\": \(windowController?.debugListState ?? "-")")
                        if let path = ProcessInfo.processInfo.environment["MMJ_SNAPSHOT"], let window = windowController?.window {
                            let capture = Process()
                            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                            let name = text.filter { $0.isLetter || $0.isNumber }
                            // With a sheet up, the sheet's own window (it's a separate window on screen).
                            let number = window.attachedSheet?.windowNumber ?? window.windowNumber
                            capture.arguments = ["-x", "-o", "-l\(number)", path.replacingOccurrences(of: ".png", with: "-\(name).png")]
                            try? capture.run()
                            capture.waitUntilExit()
                        }
                    }
                }
                if let steps = ProcessInfo.processInfo.environment["MMJ_DEBUG_RESULT"] {
                    // "thread", "people", "cancel", comma-separated: as the toolbar buttons and Cancel do.
                    NSLog("MMJ result before: \(windowController?.debugListState ?? "-")")
                    for step in steps.split(separator: ",") {
                        windowController?.debugResult(String(step))
                        try? await Task.sleep(for: .seconds(2))
                        NSLog("MMJ result \(step): \(windowController?.debugListState ?? "-")")
                        if let path = ProcessInfo.processInfo.environment["MMJ_SNAPSHOT"], let number = windowController?.window?.windowNumber {
                            let capture = Process()
                            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                            capture.arguments = ["-x", "-o", "-l\(number)", path.replacingOccurrences(of: ".png", with: "-\(step).png")]
                            try? capture.run()
                            capture.waitUntilExit()
                        }
                    }
                }
                if let spec = ProcessInfo.processInfo.environment["MMJ_DEBUG_CONTEXT_MENU"] {
                    // "row" or "row:Item title": logs the row's context menu, then runs that item.
                    let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
                    let items = windowController?.debugContextMenu(row: Int(parts[0]) ?? 0, run: parts.count > 1 ? parts[1] : nil)
                    NSLog("MMJ context menu: \(items ?? [])")
                    try? await Task.sleep(for: .seconds(3))
                    NSLog("MMJ source after: \(windowController?.debugSource(row: 0) ?? "-")")
                }
                if let text = ProcessInfo.processInfo.environment["MMJ_DEBUG_HOVER_LINK"] {
                    await windowController?.debugHoverLink(containing: text)
                    try? await Task.sleep(for: .milliseconds(500))
                }
                if let file = ProcessInfo.processInfo.environment["MMJ_RENDER_HTML_FILE"],
                    let html = try? String(contentsOfFile: file, encoding: .utf8)
                {
                    windowController?.debugRender(html: html)
                    try? await Task.sleep(for: .seconds(2))
                }
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_LAYOUT"] != nil {
                    try? await Task.sleep(for: .seconds(1))
                    NSLog("MMJ message layout: \(windowController?.debugMessageLayout ?? "-")")
                }
                if ProcessInfo.processInfo.environment["MMJ_SNAPSHOT_LOAD_REMOTE"] != nil {
                    try? await Task.sleep(for: .seconds(1))
                    windowController?.debugLoadRemote()
                    try? await Task.sleep(for: .seconds(3))
                }
                if let points = Double(ProcessInfo.processInfo.environment["MMJ_SNAPSHOT_SCROLL_MESSAGE"] ?? "") {
                    windowController?.debugScrollMessage(by: points)
                    try? await Task.sleep(for: .seconds(1))
                }
                if let points = Double(ProcessInfo.processInfo.environment["MMJ_SNAPSHOT_SCROLL"] ?? "") {
                    windowController?.debugScrollList(by: points)
                    try? await Task.sleep(for: .milliseconds(400))
                }
                if let key = ProcessInfo.processInfo.environment["MMJ_SNAPSHOT_ROUNDTRIP"] {
                    writeSnapshot(of: windowController?.window, to: path.replacingOccurrences(of: ".png", with: "-before.png"))
                    windowController?.debugSelectSidebar(key: key)
                    // MMJ_SNAPSHOT_AWAY=<seconds>: stay there that long (e.g. for mail to arrive meanwhile).
                    try? await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["MMJ_SNAPSHOT_AWAY"] ?? "1") ?? 1))
                    windowController?.debugSelectSidebar(key: "unified.inbox")
                    try? await Task.sleep(for: .seconds(1))
                }
                // MMJ_SNAPSHOT_SETTLE=<seconds>: wait after the scripted actions (e.g. for mail to arrive).
                if let settle = Double(ProcessInfo.processInfo.environment["MMJ_SNAPSHOT_SETTLE"] ?? "") {
                    try? await Task.sleep(for: .seconds(settle))
                }
                if ProcessInfo.processInfo.environment["MMJ_SNAPSHOT_FOCUS_SIDEBAR"] != nil {
                    windowController?.debugFocusSidebar()
                    try? await Task.sleep(for: .seconds(1))
                }
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_MENU"] != nil, let controller = windowController {
                    await controller.debugType("n")  // Brings the window forward with a message selected.
                    NSLog("MMJ menu: \(controller.debugMessageMenu())")
                }
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_ROWS"] != nil { windowController?.debugRowFrames() }
                if let count = Int(ProcessInfo.processInfo.environment["MMJ_DEBUG_CORR_SELECTION"] ?? "") {
                    await windowController?.debugCheckCorrespondenceSelection(rows: count)
                }
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_UNREAD_THREADS"] != nil {
                    NSLog("MMJ unread threads: \(windowController?.debugUnreadThreads.prefix(5) ?? [])")
                }
                if let mode = ProcessInfo.processInfo.environment["MMJ_DEBUG_HEADER"] {
                    windowController?.debugHeader(toggle: mode == "toggle")
                    try? await Task.sleep(for: .seconds(1))
                }
                if let keys = ProcessInfo.processInfo.environment["MMJ_DEBUG_KEYS"] {
                    // Keys typed as a user would; "|filter" after a v or gl chooses in the mailbox picker.
                    for part in keys.split(separator: " ") {
                        if part == "|snap", let path = ProcessInfo.processInfo.environment["MMJ_SNAPSHOT"] {
                            writeSnapshot(of: MailboxPicker.debugPanel, to: path.replacingOccurrences(of: ".png", with: "-picker.png"))
                            NSLog("MMJ picker rows: \(MailboxPicker.debugFirstRows) frame \(NSStringFromRect(MailboxPicker.debugPanel?.frame ?? .zero)) content \(NSStringFromRect(MailboxPicker.debugPanel?.contentLayoutRect ?? .zero))")
                            // As a click in the main window would: does the picker stay in front?
                            windowController?.window?.makeKeyAndOrderFront(nil)
                            try? await Task.sleep(for: .milliseconds(300))
                            let panel = MailboxPicker.debugPanel
                            let order = NSApp.orderedWindows.map { $0 === panel ? "picker" : $0 === windowController?.window ? "main" : "other" }
                            NSLog("MMJ picker after main window front: visible=\(panel?.isVisible ?? false) level=\(panel?.level.rawValue ?? -1) order=\(order)")
                        } else if part == "|quit" {
                            NSLog("MMJ quit requested with \(AppModel.shared?.pendingWork ?? -1) changes under way")
                            NSApp.terminate(nil)  // as ⌘Q
                        } else if part.hasPrefix("|wait:"), let seconds = Double(part.dropFirst(6)) {
                            try? await Task.sleep(for: .seconds(seconds))  // e.g. to take the server down meanwhile
                        } else if part.hasPrefix("|") {
                            // "|filter" chooses the first match; "|filter>Name" makes a submailbox Name inside it.
                            let spec = part.dropFirst().split(separator: ">", maxSplits: 1).map(String.init)
                            MailboxPicker.debugChoose(  // "+" stands for a space in the filter
                                filter: spec[0].replacingOccurrences(of: "+", with: " "), create: spec.count > 1 ? spec[1] : nil)
                            try? await Task.sleep(for: .seconds(1))
                        } else {
                            await windowController?.debugType(String(part))
                        }
                        try? await Task.sleep(for: .milliseconds(800))
                    }
                }
                if let spec = ProcessInfo.processInfo.environment["MMJ_DEBUG_GMAIL_REMOTE_CHANGE"] {
                    // "accountId|subject": waits for the watch to connect, then changes it in Gmail directly.
                    let parts = spec.split(separator: "|", maxSplits: 1).map(String.init)
                    try? await Task.sleep(for: .seconds(10))
                    await AppModel.shared.debugRemoteReadChange(accountId: parts[0], subject: parts[1])
                }
                if let accountId = ProcessInfo.processInfo.environment["MMJ_DEBUG_GMAIL_ARRIVAL"] {
                    try? await Task.sleep(for: .seconds(10))  // the watch connects first
                    await AppModel.shared.debugRemoteArrival(accountId: accountId)
                }
                if let accountId = ProcessInfo.processInfo.environment["MMJ_DEBUG_GMAIL_IMAP"] {
                    await AppModel.shared.debugGmailIMAP(accountId: accountId)
                }
                if let spec = ProcessInfo.processInfo.environment["MMJ_DEBUG_MESSAGE_ACTIONS"] {
                    // "subject|action,action,…" on the newest message with that subject; after each, a sync,
                    // then its mailboxes and flags as the server reports them. Actions: read, unread, flag,
                    // unflag, archive, inbox, delete, junk, notjunk.
                    let parts = spec.split(separator: "|", maxSplits: 1).map(String.init)
                    let model = AppModel.shared!
                    func state(_ id: Int64) -> String {
                        let boxes = ((try? model.store.mailboxIDs(messageIds: [id]))?[id] ?? []).compactMap { box in
                            (try? model.store.mailboxes())?.first { $0.id == box }?.name
                        }
                        let row = (try? model.store.rows(ids: [id]))?.first
                        return "mailboxes \(boxes.sorted()) seen \(row?.isSeen ?? false) flagged \(row?.isFlagged ?? false)"
                    }
                    let found = ((try? model.store.messageIDs(scope: .everything)) ?? []).first { (try? model.store.detail(id: $0))?.subject == parts[0] }
                    if let id = found, let accountId = (try? model.store.refs(ids: [id]))?.first?.accountId {
                        NSLog("MMJ message actions on \(parts[0]): before \(state(id))")
                        for action in parts[1].split(separator: ",").map(String.init) {
                            let message: AppModel.MessageAction? = switch action {
                            case "read": .markRead
                            case "unread": .markUnread
                            case "flag": .flag
                            case "unflag": .unflag
                            case "archive": .archive
                            case "inbox": .moveToRole("inbox")
                            case "delete": .delete
                            case "junk": .junk
                            case "notjunk": .notJunk
                            default: nil
                            }
                            guard let message else { continue }
                            model.perform(message, on: [id]) { _ in false }
                            try? await Task.sleep(for: .seconds(4))
                            model.sync(accountId: accountId)
                            try? await Task.sleep(for: .seconds(6))
                            NSLog("MMJ message actions after \(action): \(state(id))")
                        }
                    } else {
                        NSLog("MMJ message actions: no message \(parts[0])")
                    }
                }
                if let actions = ProcessInfo.processInfo.environment["MMJ_DEBUG_ACTIONS"] {
                    // Comma-separated toolbar actions, 3 s apart.
                    for name in actions.split(separator: ",") {
                        windowController?.debugPerform(String(name))
                        try? await Task.sleep(for: .seconds(3))
                        NSLog("MMJ after \(name): selection \(windowController?.debugSelection ?? [])")
                    }
                }
                // MMJ_DEBUG_SEND=1 (with MMJ_DEBUG_ACTIONS opening a compose window): fill it from MMJ_DEBUG_*,
                // send it (unless MMJ_DEBUG_NOSEND) and snapshot it to <snapshot>-compose.png.
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_SEND"] != nil {
                    try? await Task.sleep(for: .seconds(2))
                    ComposeWindowController.debugSendFrontmost(ProcessInfo.processInfo.environment)
                    if let count = Int(ProcessInfo.processInfo.environment["MMJ_DEBUG_TAB"] ?? ""),
                        let window = ComposeWindowController.debugSnapshotFrontmost()
                    { debugLogTabOrder(in: window, count: count) }
                    try? await Task.sleep(for: .milliseconds(500))
                    writeSnapshot(of: ComposeWindowController.debugSnapshotFrontmost(), to: path.replacingOccurrences(of: ".png", with: "-compose.png"))
                    // Also a real screen capture of just that window (what the display shows).
                    if let number = ComposeWindowController.debugSnapshotFrontmost()?.windowNumber {
                        NSApp.activate()
                        ComposeWindowController.debugSnapshotFrontmost()?.makeKeyAndOrderFront(nil)
                        try? await Task.sleep(for: .seconds(1))
                        let capture = Process()
                        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        capture.arguments = ["-x", "-o", "-l\(number)", path.replacingOccurrences(of: ".png", with: "-screen.png")]
                        try? capture.run()
                        capture.waitUntilExit()
                    }
                    try? await Task.sleep(for: .seconds(4))
                }
                if let subject = ProcessInfo.processInfo.environment["MMJ_DEBUG_OPEN_DRAFT"] {
                    // Opens the draft with this subject as a double-click on it does, then logs the window.
                    let store = AppModel.shared.store
                    let id = ((try? store.messageIDs(scope: .role("drafts"))) ?? []).first { (try? store.detail(id: $0))?.subject == subject }
                    if let id {
                        AppModel.shared.openDraft(messageId: id, window: windowController?.window)
                        if ProcessInfo.processInfo.environment["MMJ_DEBUG_OPEN_TWICE"] != nil {
                            try? await Task.sleep(for: .seconds(2))
                            AppModel.shared.openDraft(messageId: id, window: windowController?.window)
                        }
                        try? await Task.sleep(for: .seconds(3))
                        ComposeWindowController.debugLogFrontmost()
                        if let action = ProcessInfo.processInfo.environment["MMJ_DEBUG_DRAFT_THEN"] {
                            await ComposeWindowController.debugEditThen(action, text: "\nMore text.")
                        }
                    } else {
                        NSLog("MMJ draft: no draft \"\(subject)\"")
                    }
                }
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_QUIT"] != nil,
                    let window = ComposeWindowController.debugSnapshotFrontmost()
                {
                    // Quits as ⌘Q would, then captures the compose window (its prompt, if any).
                    NSApp.terminate(nil)
                    try? await Task.sleep(for: .seconds(1.5))
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", path.replacingOccurrences(of: ".png", with: "-quit.png")]
                    try? capture.run()
                    capture.waitUntilExit()
                    NSLog("MMJ quit: still running, prompt shown=\(window.attachedSheet != nil)")
                }
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_ATTACHMENTS"] != nil {
                    await windowController?.debugCheckAttachments()
                    try? await Task.sleep(for: .seconds(2))
                }
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_RAW"] != nil {
                    await windowController?.debugCheckRawMessage()
                }
                if let path = ProcessInfo.processInfo.environment["MMJ_DOCK_RENDER"] {
                    if ProcessInfo.processInfo.environment["MMJ_DOCK_PREVIEW"] != nil {
                        AppModel.shared.dockCounters?.isPreviewing = true
                    }
                    AppModel.shared.dockCounters?.update()
                    AppModel.shared.dockCounters?.debugRender(to: path)
                    AppModel.shared.dockCounters?.debugRender(
                        to: path.replacingOccurrences(of: ".png", with: "-long.png"),
                        values: [.topLeft: 12_345, .topRight: 123_456, .bottomLeft: 7, .bottomRight: 2_345_678])
                }
                if let keys = ProcessInfo.processInfo.environment["MMJ_DEBUG_EXPAND"] {
                    for key in keys.split(separator: ",") { windowController?.debugExpandSidebar(key: String(key)) }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                NSLog("MMJ correspondence \(windowController?.debugCorrespondenceThreads ?? "")")
                if let mode = ProcessInfo.processInfo.environment["MMJ_DEBUG_COLLAPSE"] {
                    windowController?.debugCollapseFirstThread(expand: mode != "collapse")
                    if mode == "fold" {
                        try? await Task.sleep(for: .seconds(1))
                        windowController?.debugOpenFirstBranch()
                        try? await Task.sleep(for: .seconds(1))
                        if ProcessInfo.processInfo.environment["MMJ_DEBUG_LEFT"] != nil {
                            await windowController?.debugLeftArrows(fromRow: 2, times: 3)
                        }
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                NSLog("MMJ inbox badge after: \(windowController?.debugInboxBadge ?? -1)")
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_BACK"] != nil {
                    NSLog("MMJ before back: selected \(windowController?.debugSelection ?? [])")
                    windowController?.goBack(nil)
                    try? await Task.sleep(for: .seconds(1))
                    NSLog("MMJ after back: selected \(windowController?.debugSelection ?? [])")
                    windowController?.goForward(nil)
                    try? await Task.sleep(for: .seconds(1))
                    NSLog("MMJ after forward: selected \(windowController?.debugSelection ?? [])")
                }
                var target = windowController?.window
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_NEW_SMART"] != nil {
                    windowController?.newSmartMailbox(nil)
                    try? await Task.sleep(for: .seconds(1.5))
                    target = NSApp.windows.first { $0.windowController is MailboxEditorWindowController } ?? target
                }
                // MMJ_SNAPSHOT_EDITOR="<sidebar key>|<tab>": the mailbox editor on that mailbox and tab.
                if let spec = ProcessInfo.processInfo.environment["MMJ_SNAPSHOT_EDITOR"] {
                    let parts = spec.split(separator: "|").map(String.init)
                    MailboxEditorWindowController.show(key: parts[0], model: AppModel.shared, over: target)
                    try? await Task.sleep(for: .seconds(1))
                    if parts.count > 1 { MailboxEditorWindowController.debugShow(tab: parts[1]) }
                    if let width = Double(ProcessInfo.processInfo.environment["MMJ_DEBUG_EDITOR_WIDTH"] ?? ""),
                        let editor = NSApp.windows.first(where: { $0.windowController is MailboxEditorWindowController })
                    {
                        var frame = editor.frame
                        frame.size.width = width
                        editor.setFrame(frame, display: true)  // as dragging its edge would
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    // MMJ_DEBUG_EDITOR_REOPEN=<width>: closes the editor, opens it again and drags it to that width.
                    if let width = Double(ProcessInfo.processInfo.environment["MMJ_DEBUG_EDITOR_REOPEN"] ?? ""),
                        let editor = NSApp.windows.first(where: { $0.windowController is MailboxEditorWindowController })
                    {
                        editor.performClose(nil)
                        try? await Task.sleep(for: .milliseconds(500))
                        MailboxEditorWindowController.show(key: parts[0], model: AppModel.shared, over: target)
                        try? await Task.sleep(for: .milliseconds(500))
                        let editors = NSApp.windows.filter { $0.windowController is MailboxEditorWindowController }
                        if let again = editors.first(where: \.isVisible) {
                            NSLog("MMJ editor reopened at \(again.frame.size), autosave \"\(again.frameAutosaveName)\", \(editors.count) editor window(s)")
                            var frame = again.frame
                            frame.size.width = width
                            again.setFrame(frame, display: true)
                            try? await Task.sleep(for: .milliseconds(500))
                        }
                    }
                    if ProcessInfo.processInfo.environment["MMJ_DEBUG_EDITOR_HOVER"] != nil { MailboxEditorWindowController.debugHoverTabs() }
                    if ProcessInfo.processInfo.environment["MMJ_DEBUG_EDITOR_TIPS"] != nil { MailboxEditorWindowController.debugLogToolTips() }
                    if ProcessInfo.processInfo.environment["MMJ_DEBUG_MAILBOX_MENU"] != nil { MailboxEditorWindowController.debugDumpMailboxMenu() }
                    if ProcessInfo.processInfo.environment["MMJ_DEBUG_DUP_UNGROUP"] != nil { MailboxEditorWindowController.debugDuplicateAndUngroup() }
                    if ProcessInfo.processInfo.environment["MMJ_DEBUG_REMOVE_ROW"] != nil { MailboxEditorWindowController.debugRemoveFirstRow() }
                    if ProcessInfo.processInfo.environment["MMJ_DEBUG_SPLIT_MENU"] != nil { MailboxEditorWindowController.debugDumpSplitMenu() }
                    if ProcessInfo.processInfo.environment["MMJ_DEBUG_PRESS_ADD"] != nil { MailboxEditorWindowController.debugPressAddRule() }
                    if ProcessInfo.processInfo.environment["MMJ_DEBUG_ADD_RULE"] != nil {
                        MailboxEditorWindowController.debugClickAddRule()
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    if let row = Int(ProcessInfo.processInfo.environment["MMJ_DEBUG_RULE_ROW"] ?? "") {
                        MailboxEditorWindowController.debugSelectRule(row: row)
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    if let count = Int(ProcessInfo.processInfo.environment["MMJ_DEBUG_TAB"] ?? "") {
                        MailboxEditorWindowController.debugTab(count: count)  // Tab through the editor's fields
                    }
                    if ProcessInfo.processInfo.environment["MMJ_DEBUG_EDITOR_SCROLLING"] != nil {
                        NSLog("MMJ editor scroll: \(MailboxEditorWindowController.debugEditorScroll)")
                        if let scroll = MailboxEditorWindowController.debugEditor?.enclosingScrollView {
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))  // as the scroll wheel would
                            scroll.reflectScrolledClipView(scroll.contentView)
                        }
                    }
                    if let spec = ProcessInfo.processInfo.environment["MMJ_DEBUG_EDITOR_MOVE"] {
                        MailboxEditorWindowController.debugMoveSidebar(spec)  // dragging in the editor's sidebar
                        try? await Task.sleep(for: .seconds(1))
                        NSLog("MMJ main sidebar after editor move: \(windowController?.debugSidebarOrder ?? "-")")
                    }
                    if let width = ProcessInfo.processInfo.environment["MMJ_DEBUG_EDITOR_SIDEBAR"] {
                        MailboxEditorWindowController.debugSidebarWidth(set: Double(width).map { CGFloat($0) })
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    if let steps = ProcessInfo.processInfo.environment["MMJ_DEBUG_DRAG_ROWS"] {
                        MailboxEditorWindowController.debugDrag(steps)  // "from:x:y;..." in the editor
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    if let text = ProcessInfo.processInfo.environment["MMJ_DEBUG_TYPE_ADD"] {
                        MailboxEditorWindowController.debugTypeThenAdd(text)  // type into a condition, then its ⊕
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    if let points = Double(ProcessInfo.processInfo.environment["MMJ_DEBUG_EDITOR_SCROLL"] ?? "") {
                        MailboxEditorWindowController.debugScrollSidebar(by: points)
                    }
                    try? await Task.sleep(for: .seconds(1))
                    if parts.count > 2 {
                        MailboxEditorWindowController.debugAddRow(text: parts[2])
                        try? await Task.sleep(for: .seconds(1))
                    }
                    target = NSApp.windows.first { $0.windowController is MailboxEditorWindowController }
                }
                if ProcessInfo.processInfo.environment["MMJ_SNAPSHOT_SETTINGS"] != nil {
                    SettingsWindowController.shared.show()
                    try? await Task.sleep(for: .seconds(1))
                    target = SettingsWindowController.shared.window
                }
                if let spec = ProcessInfo.processInfo.environment["MMJ_DEBUG_EDIT_ACCOUNT"] {
                    // "accountId|new description|password" (empty password keeps it).
                    let p = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                    windowController?.editAccount(id: p[0])
                    try? await Task.sleep(for: .milliseconds(500))
                    windowController?.accountSettings?.debugEdit(
                        description: p[1], password: p[2], emails: p.count > 3 ? p[3] : nil)
                    try? await Task.sleep(for: .seconds(5))
                    let record = try? AppModel.shared.store.account(id: p[0])
                    NSLog("MMJ edit result: open=\(windowController?.accountSettings != nil) name=\(record?.name ?? "nil") url=\(record?.sessionURL ?? "") emails=\(record?.emailAddresses ?? "")")
                    let sheet = windowController?.accountSettings?.window?.attachedSheet
                    NSLog("MMJ edit alert: \((sheet?.contentView?.subviews.compactMap { ($0 as? NSTextField)?.stringValue } ?? []).joined(separator: " | "))")
                    NSLog("MMJ edit identities: \(((try? AppModel.shared.store.identities()) ?? []).filter { $0.accountId == p[0] }.map { "\($0.name) <\($0.email)>" })")
                }
                if let name = ProcessInfo.processInfo.environment["MMJ_DEBUG_REMOVE_ALERT"] {
                    // The Remove Account alert, laid out and captured as it shows (without waiting for an answer).
                    let alert = SidebarViewController.removeAccountAlert(name: name)
                    alert.layout()
                    alert.window.center()
                    alert.window.orderFront(nil)
                    try? await Task.sleep(for: .seconds(1))
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-l\(alert.window.windowNumber)", path.replacingOccurrences(of: ".png", with: "-remove.png")]
                    try? capture.run()
                    capture.waitUntilExit()
                    alert.window.orderOut(nil)
                }
                if let list = ProcessInfo.processInfo.environment["MMJ_DEBUG_ACCOUNT_TYPE"] {
                    // Comma-separated addresses typed into a new account's window, one after another: logs the
                    // account type each gives (and captures the window as <MMJ_SNAPSHOT_ACCOUNT>-<n>.png).
                    windowController?.addAccount(nil)
                    for (n, address) in list.split(separator: ",").map(String.init).enumerated() {
                        windowController?.accountSettings?.debugTypeEmail(address, user: nil)
                        try? await Task.sleep(for: .seconds(4))
                        NSLog("MMJ account type \(address): \(windowController?.accountSettings?.debugTypeState ?? "-")")
                        if let path = ProcessInfo.processInfo.environment["MMJ_SNAPSHOT_ACCOUNT"],
                            let number = windowController?.accountSettings?.window?.windowNumber
                        {
                            let capture = Process()
                            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                            capture.arguments = ["-x", "-o", "-l\(number)", path.replacingOccurrences(of: ".png", with: "-\(n).png")]
                            try? capture.run()
                            capture.waitUntilExit()
                        }
                    }
                    windowController?.accountSettings?.close()
                }
                if let spec = ProcessInfo.processInfo.environment["MMJ_DEBUG_TYPE_EMAIL"] {
                    // "email" or "email|user": typed into a new account's window (the user name first, if given).
                    let parts = spec.split(separator: "|").map(String.init)
                    windowController?.addAccount(nil)
                    windowController?.accountSettings?.debugTypeEmail(parts[0], user: parts.count > 1 ? parts[1] : nil)
                    windowController?.accountSettings?.close()
                }
                if let spec = ProcessInfo.processInfo.environment["MMJ_DEBUG_ADD_ACCOUNT"] {
                    // Adds an account through the window, checks it, then removes it again.
                    windowController?.addAccount(nil)
                    windowController?.accountSettings?.debugAdd(spec)
                    try? await Task.sleep(for: .seconds(6))
                    if let path = ProcessInfo.processInfo.environment["MMJ_SNAPSHOT_ACCOUNT"],
                        let number = windowController?.accountSettings?.window?.windowNumber
                    {
                        let capture = Process()
                        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        capture.arguments = ["-x", "-o", "-l\(number)", path]
                        try? capture.run()
                        capture.waitUntilExit()
                    }
                    let added = (try? AppModel.shared.store.accounts())?.first { $0.name == "Dave (window test)" }
                    NSLog("MMJ account window: open=\(windowController?.accountSettings != nil) added=\(added.map { "\($0.sessionURL) user=\($0.username) fullName=\($0.fullName) emails=\($0.emailAddresses)" } ?? "no")")
                    NSLog("MMJ account window: my addresses include dave=\((try? AppModel.shared.store.myAddresses())?.contains("dave@mmj.test") ?? false)")
                    if let added { AppModel.shared.removeAccount(id: added.id) }
                    try? await Task.sleep(for: .seconds(2))
                }
                if ProcessInfo.processInfo.environment["MMJ_SNAPSHOT_SHEET"] != nil {
                    windowController?.addAccount(nil)
                    try? await Task.sleep(for: .seconds(1.5))
                    target = windowController?.accountSettings?.window
                }
                // MMJ_DEBUG_SYMBOL_PANEL=<sidebar key>: Symbol ▸ Custom… on it (=key|list: with its list open,
                // captured with the list as <snapshot>-list.png).
                if let spec = ProcessInfo.processInfo.environment["MMJ_DEBUG_SYMBOL_PANEL"] {
                    let parts = spec.split(separator: "|").map(String.init)
                    SymbolPanel.show(key: parts[0], defaultSymbol: "folder")
                    try? await Task.sleep(for: .seconds(1))
                    target = NSApp.windows.first { $0 is SymbolPanel } ?? target
                    if parts.count > 1, let frame = target?.frame, let screen = NSScreen.screens.first {
                        NSApp.activate()
                        SymbolPanel.debugOpenList()
                        try? await Task.sleep(for: .seconds(1))
                        let rect = "\(Int(frame.minX)),\(Int(screen.frame.maxY - frame.maxY)),\(Int(frame.width)),\(Int(frame.height) + 220)"
                        let capture = Process()
                        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        capture.arguments = ["-x", "-R\(rect)", path.replacingOccurrences(of: ".png", with: "-list.png")]
                        try? capture.run()
                        capture.waitUntilExit()
                    }
                }
                writeSnapshot(of: target, to: path)
                // MMJ_SNAPSHOT_SCREEN: also a real screen capture of that window (<snapshot>-screen.png).
                if ProcessInfo.processInfo.environment["MMJ_SNAPSHOT_SCREEN"] != nil, let number = target?.windowNumber {
                    NSApp.activate()
                    target?.makeKeyAndOrderFront(nil)
                    try? await Task.sleep(for: .seconds(1))
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l\(number)", path.replacingOccurrences(of: ".png", with: "-screen.png")]
                    try? capture.run()
                    capture.waitUntilExit()
                }
                await windowController?.debugSnapshotWeb(to: path.replacingOccurrences(of: ".png", with: "-web.png"))
            }
        }

        private func writeSnapshot(of window: NSWindow?, to path: String) {
            guard let frameView = window?.contentView?.superview,
                let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
            else { return }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    #endif

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Unsent messages are saved as drafts first. Then, with changes still on their way to the servers,
    /// it waits for them (see QuitProgress) and quits once they're done. The wait isn't held inside the
    /// quit itself: while AppKit waits on a quit, the main actor's tasks don't run, so the work could
    /// never finish. The quit is called off, and made again when the work is done.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quittingAfterWork { return .terminateNow }
        let saving = ComposeWindowController.saveUnsentBeforeQuit { saved in
            if saved { self.quitAfterPendingWork() }  // else the one not saved says why, and the app stays
        }
        if saving { return .terminateCancel }
        guard let model = AppModel.shared, model.pendingWork > 0 else { return .terminateNow }
        quitAfterPendingWork()
        return .terminateCancel
    }

    /// Set once the server work is done, to let the final quit through.
    private var quittingAfterWork = false

    private func quitAfterPendingWork() {
        guard let model = AppModel.shared else { return NSApp.terminate(nil) }
        QuitProgress.wait(for: model) { [weak self] quit in
            guard quit else { return }
            self?.quittingAfterWork = true
            NSApp.terminate(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController?.showWindow(nil) }
        return true
    }
}

@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, appName)
        app.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        let services = NSMenu()
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File, Edit and View grouped as MailMate groups them, with the commands MailMateJ has.
        let file = submenu(main, "File")
        file.addItem(withTitle: "New Message", action: #selector(MainWindowController.newMessage(_:)), keyEquivalent: "n")
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(.separator())
        file.addItem(withTitle: "Add Account…", action: #selector(MainWindowController.addAccount(_:)), keyEquivalent: "")

        let edit = submenu(main, "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find…", action: #selector(MainWindowController.focusSearch(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .option]

        let view = submenu(main, "View")
        view.addItem(withTitle: "Organize by Thread", action: #selector(MainWindowController.toggleThreads(_:)), keyEquivalent: "T")
        view.addItem(.separator())
        view.addItem(withTitle: "Back in History", action: #selector(MainWindowController.goBack(_:)), keyEquivalent: "[")
        view.addItem(withTitle: "Forward in History", action: #selector(MainWindowController.goForward(_:)), keyEquivalent: "]")
        view.addItem(.separator())
        view.addItem(withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        // MailMate's Mailbox menu: New Smart Mailbox, the selected mailbox's commands (filled in as the
        // menu opens), then syncing.
        let mailbox = submenu(main, "Mailbox")
        mailbox.addItem(withTitle: "New Smart Mailbox", action: #selector(MainWindowController.newSmartMailbox(_:)), keyEquivalent: "n")
            .keyEquivalentModifierMask = [.command, .control]
        mailbox.addItem(withTitle: "Synchronize", action: #selector(MainWindowController.synchronize(_:)), keyEquivalent: "N")
        mailbox.delegate = MailboxMenu.shared

        // MailMate's Message menu and shortcuts, for the commands MailMateJ has.
        let message = submenu(main, "Message")
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!), up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        func add(
            _ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command
        ) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: key).keyEquivalentModifierMask = modifiers
        }
        add(message, "Send", #selector(ComposeWindowController.sendMessage(_:)), "d", [.command, .shift])
        message.addItem(.separator())
        add(message, "Reply", #selector(MainWindowController.reply(_:)), "r")
        add(message, "Reply All", #selector(MainWindowController.replyAll(_:)), "r", [.command, .shift])
        add(message, "Forward", #selector(MainWindowController.forward(_:)), "f", [.command, .shift])
        add(message, "Move to Archive", #selector(MainWindowController.archiveMessages(_:)), "m", [.command, .shift])
        add(message, "Move to Junk", #selector(MainWindowController.junkMessages(_:)), "j", [.command, .shift])
        add(message, "Move to Mailbox…", #selector(MainWindowController.moveToMailbox(_:)), "t", [.command, .option])
        add(message, "Delete", #selector(MainWindowController.deleteMessages(_:)), "\u{8}", [])  // Shown as ⌫; the key itself is handled by the key bindings.
        message.addItem(.separator())
        let flag = NSMenu(title: "Flag")
        add(flag, "Flag", #selector(MainWindowController.flagMessages(_:)))
        add(flag, "Unflag", #selector(MainWindowController.unflagMessages(_:)))
        message.addItem(withTitle: "Flag", action: nil, keyEquivalent: "").submenu = flag
        add(message, "Mark as Unread", #selector(MainWindowController.toggleReadState(_:)), "u", [.command, .shift])
        message.addItem(.separator())
        add(message, "Next Message", #selector(MainWindowController.nextMessage(_:)), down)
        add(message, "Previous Message", #selector(MainWindowController.previousMessage(_:)), up)
        add(message, "Next Unread Message", #selector(MainWindowController.nextUnreadMessage(_:)), down, [.command, .option])
        add(message, "Previous Unread Message", #selector(MainWindowController.previousUnreadMessage(_:)), up, [.command, .option])
        message.addItem(.separator())
        add(message, "Next Thread", #selector(MainWindowController.nextThread(_:)), down, [.command, .control])
        add(message, "Previous Thread", #selector(MainWindowController.previousThread(_:)), up, [.command, .control])
        add(message, "Next Unread Thread", #selector(MainWindowController.nextUnreadThread(_:)), down, [.command, .control, .option])
        add(message, "Previous Unread Thread", #selector(MainWindowController.previousUnreadThread(_:)), up, [.command, .control, .option])
        add(message, "Root of Thread", #selector(MainWindowController.rootOfThread(_:)), "r", [.command, .control])
        add(message, "Last of Thread", #selector(MainWindowController.lastOfThread(_:)), "l", [.command, .control])
        message.addItem(.separator())
        add(message, "Save Attachments…", #selector(MainWindowController.saveAttachments(_:)), "a", [.command, .option, .shift])
        add(message, "Quick Look Attachments…", #selector(MainWindowController.quickLookAttachments(_:)), "y")
        add(message, "Open Attachments", #selector(MainWindowController.openAttachments(_:)), "\r", [.command, .option])
        message.addItem(.separator())
        add(message, "Show in Finder", #selector(MainWindowController.showInFinder(_:)))
        message.addItem(.separator())
        add(message, "Go to Mailbox…", #selector(MainWindowController.goToMailbox(_:)), "t")

        let window = submenu(main, "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        return main
    }

    /// Fills the Mailbox menu with the selected mailbox's commands each time it opens, between New Smart
    /// Mailbox and Synchronize (which stay, for their shortcuts), naming the mailbox in Synchronize.
    @MainActor
    final class MailboxMenu: NSObject, NSMenuDelegate {
        static let shared = MailboxMenu()

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let newSmart = menu.items.first(where: { $0.action == #selector(MainWindowController.newSmartMailbox(_:)) }),
                let synchronize = menu.items.first(where: { $0.action == #selector(MainWindowController.synchronize(_:)) })
            else { return }
            menu.removeAllItems()
            menu.addItem(newSmart)
            let controller = NSApp.mainWindow?.windowController as? MainWindowController
                ?? NSApp.windows.lazy.compactMap { $0.windowController as? MainWindowController }.first
            let groups = controller?.mailboxMenuGroups ?? []
            for group in groups {
                menu.addItem(.separator())
                group.forEach(menu.addItem)
            }
            menu.addItem(.separator())
            synchronize.title = controller?.synchronizeTitle ?? "Synchronize"
            menu.addItem(synchronize)
            controller?.syncStatusItems.forEach(menu.addItem)
        }
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
