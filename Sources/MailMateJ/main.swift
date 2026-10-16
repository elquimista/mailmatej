import AppKit

/// "MailMateJ" for release builds, "MailMateJ Dev" for debug builds (set by scripts/bundle.sh).
let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "MailMateJ"

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
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
                if let steps = Int(ProcessInfo.processInfo.environment["MMJ_SNAPSHOT_STEPS"] ?? "") {
                    for _ in 0..<steps {
                        windowController?.debugSelectNextMessage()
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                }
                // MMJ_SNAPSHOT_ROUNDTRIP=<sidebar key>: switch to that mailbox and back before the snapshot.
                if let file = ProcessInfo.processInfo.environment["MMJ_RENDER_HTML_FILE"],
                    let html = try? String(contentsOfFile: file, encoding: .utf8)
                {
                    windowController?.debugRender(html: html)
                    try? await Task.sleep(for: .seconds(2))
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
                if ProcessInfo.processInfo.environment["MMJ_SNAPSHOT_FOCUS_SIDEBAR"] != nil {
                    windowController?.debugFocusSidebar()
                    try? await Task.sleep(for: .seconds(1))
                }
                var target = windowController?.window
                if ProcessInfo.processInfo.environment["MMJ_SNAPSHOT_SHEET"] != nil {
                    windowController?.addAccount(nil)
                    try? await Task.sleep(for: .seconds(1.5))
                    target = target?.attachedSheet
                }
                writeSnapshot(of: target, to: path)
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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
        view.addItem(withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        let mailbox = submenu(main, "Mailbox")
        mailbox.addItem(withTitle: "Get All Mail", action: #selector(MainWindowController.getAllMail(_:)), keyEquivalent: "N")

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
