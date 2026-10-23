import AppKit

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
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_BADGES"] != nil {
                    NSLog("MMJ badges: \(windowController?.debugSidebarBadges ?? "")")
                }
                if let spec = ProcessInfo.processInfo.environment["MMJ_DEBUG_SIDEBAR_MOVE"] {
                    windowController?.debugMoveSidebar(spec)
                    try? await Task.sleep(for: .milliseconds(500))
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
                    AppModel.shared.deleteSmartMailbox(id: id)  // as Delete Smart Mailbox… does
                    try? await Task.sleep(for: .seconds(1))
                }
                NSLog("MMJ inbox badge before: \(windowController?.debugInboxBadge ?? -1)")
                if let steps = Int(ProcessInfo.processInfo.environment["MMJ_SNAPSHOT_STEPS"] ?? "") {
                    for _ in 0..<steps {
                        windowController?.debugSelectNextMessage()
                        try? await Task.sleep(for: .milliseconds(400))
                    }
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
                if let spec = ProcessInfo.processInfo.environment["MMJ_DEBUG_CONTEXT_MENU"] {
                    // "row" or "row:Item title": logs the row's context menu, then runs that item.
                    let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
                    let items = windowController?.debugContextMenu(row: Int(parts[0]) ?? 0, run: parts.count > 1 ? parts[1] : nil)
                    NSLog("MMJ context menu: \(items ?? [])")
                    try? await Task.sleep(for: .seconds(3))
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
                    try? await Task.sleep(for: .seconds(1))
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
                    if ProcessInfo.processInfo.environment["MMJ_DEBUG_EDITOR_HOVER"] != nil { MailboxEditorWindowController.debugHoverTabs() }
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
                if let spec = ProcessInfo.processInfo.environment["MMJ_DEBUG_ADD_ACCOUNT"] {
                    // Adds an account through the window, checks it, then removes it again.
                    windowController?.addAccount(nil)
                    windowController?.accountSettings?.debugAdd(spec)
                    try? await Task.sleep(for: .seconds(6))
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

        let file = submenu(main, "File")
        file.addItem(withTitle: "New Message", action: #selector(MainWindowController.newMessage(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "Add Account…", action: #selector(MainWindowController.addAccount(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = submenu(main, "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find…", action: #selector(MainWindowController.focusSearch(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .option]

        let view = submenu(main, "View")
        view.addItem(withTitle: "Show Threads", action: #selector(MainWindowController.toggleThreads(_:)), keyEquivalent: "")
        view.addItem(withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        let mailbox = submenu(main, "Mailbox")
        mailbox.addItem(withTitle: "Get All Mail", action: #selector(MainWindowController.getAllMail(_:)), keyEquivalent: "N")
        mailbox.addItem(.separator())
        let newSmart = mailbox.addItem(
            withTitle: "New Smart Mailbox", action: #selector(MainWindowController.newSmartMailbox(_:)), keyEquivalent: "n")
        newSmart.keyEquivalentModifierMask = [.command, .option]

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
