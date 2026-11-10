import AppKit
import MailSync
import Security
import os

private let updateLog = Logger(subsystem: "app.mailmatej", category: "update")

/// Check for Update, as MailMate's: once a day when Settings › Software Update watches for releases
/// (and on asking), the newest release of the chosen channel is looked for among the public releases
/// repository's GitHub releases (see `SoftwareUpdate`); a newer one is offered, downloaded (asking first, unless set
/// not to), checked to be signed as this copy is (its designated requirement, which the keychain trusts
/// too), and installed in this copy's place, which then relaunches.
@MainActor
final class SoftwareUpdater {
    static let shared = SoftwareUpdater()
    /// Posted when checking starts or ends, or a setting changes (Settings › Software Update shows it).
    static let didChange = Notification.Name("SoftwareUpdaterDidChange")

    enum Channel: String, CaseIterable {
        case release, beta
        var title: String { self == .release ? "Normal releases" : "Beta releases" }
    }

    // MARK: Settings (MailMate's keys)

    /// Watch for: checks once a day.
    var watches: Bool {
        get { !UserDefaults.standard.bool(forKey: "SoftwareUpdateDisablePolling") }
        set {
            UserDefaults.standard.set(!newValue, forKey: "SoftwareUpdateDisablePolling")
            changed()
        }
    }

    var channel: Channel {
        get { Channel(rawValue: UserDefaults.standard.string(forKey: "SoftwareUpdateChannel") ?? "") ?? .release }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "SoftwareUpdateChannel") }
    }

    /// Ask before downloading updates (a daily check's; one asked for always asks). Off, as the user has
    /// MailMate's: a newer release downloads by itself, then asks to Install & Relaunch.
    var asksBeforeDownloading: Bool {
        get { UserDefaults.standard.object(forKey: "SoftwareUpdateAskBeforeUpdating") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "SoftwareUpdateAskBeforeUpdating") }
    }

    /// When releases were last looked at, successfully.
    private(set) var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: "SoftwareUpdateLastPoll") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "SoftwareUpdateLastPoll") }
    }

    // MARK: State

    private(set) var checking = false
    /// Why the last check failed (nil: it didn't).
    private(set) var lastError: String?
    /// The public repository releases come from ("owner/name"), stamped at build time.
    let repository: String? = {
        #if DEBUG
            if let repository = ProcessInfo.processInfo.environment["MMJ_DEBUG_UPDATE_REPO"] { return repository }
        #endif
        return Bundle.main.object(forInfoDictionaryKey: "MMJUpdateRepository") as? String
    }()
    let current = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(SoftwareUpdate.Version.init)
    private var window: UpdateWindowController?
    private var download: Task<Void, Never>?
    /// The folder a download unpacks in (gone with it).
    private var downloadFolder: URL?

    private var github: SoftwareUpdate.GitHub? {
        guard let repository else { return nil }
        #if DEBUG
            if let api = ProcessInfo.processInfo.environment["MMJ_DEBUG_UPDATE_API"].flatMap(URL.init(string:)) {
                return SoftwareUpdate.GitHub(repository: repository, api: api)
            }
        #endif
        return SoftwareUpdate.GitHub(repository: repository)
    }

    private func changed() { NotificationCenter.default.post(name: Self.didChange, object: self) }

    /// The daily check: a minute after launch, then each hour sees whether a day has passed.
    func start() {
        Task {
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                checkIfDue()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private func checkIfDue() {
        guard watches, window == nil else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 24 * 3600 { return }
        check(userInitiated: false)
    }

    // MARK: Checking

    /// Looks for a newer release: asked for (Check for Update, Check Now), it says what it found, up to
    /// date or not; the daily check says only when there's a newer one.
    func check(userInitiated: Bool) {
        if let window {
            if userInitiated { window.showWindow(nil) }  // one already offered, downloading or ready
            return
        }
        guard !checking else { return }
        guard let current else { return }
        guard let github else {
            if userInitiated { show(.failed("Error Checking for Update", "This copy of MailMateJ doesn’t say where its releases are.")) }
            return
        }
        checking = true
        lastError = nil
        changed()
        Task {
            defer {
                checking = false
                changed()
            }
            do {
                let releases = try await github.releases()
                lastCheck = Date()
                let latest = SoftwareUpdate.latest(in: releases, betas: channel == .beta)
                guard let release = latest, let version = release.version, current < version else {
                    updateLog.notice("Up to date: \(current, privacy: .public) (latest \(latest?.tagName ?? "-", privacy: .public))")
                    // A copy built after the latest release (MailMate's "prerelease") isn't the latest version.
                    if userInitiated { show(latest?.version.map { $0 < current } == true ? .newerThanReleases(latest!) : .upToDate) }
                    return
                }
                updateLog.notice("\(release.tagName, privacy: .public) is available (running \(current, privacy: .public))")
                if userInitiated || asksBeforeDownloading { show(.available(release)) } else { startDownload(release) }
            } catch {
                lastError = error.localizedDescription
                updateLog.error("Checking for an update: \(error.localizedDescription, privacy: .public)")
                if userInitiated { show(.failed("Error Checking for Update", error.localizedDescription)) }
            }
        }
    }

    // MARK: Downloading

    private func startDownload(_ release: SoftwareUpdate.Release) {
        guard let asset = release.app, let version = release.version, let github else { return }
        show(.downloading(release, fraction: 0))
        download = Task {
            do {
                let folder = try FileManager.default.url(
                    for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: Bundle.main.bundleURL, create: true)
                downloadFolder = folder
                let zip = folder.appendingPathComponent(asset.name)
                var shown = -1
                try await github.download(asset, to: zip) { bytes in
                    let percent = Int(bytes * 100 / Int64(max(asset.size, 1)))
                    Task { @MainActor in
                        guard percent != shown, !Task.isCancelled else { return }
                        shown = percent
                        self.window?.show(.downloading(release, fraction: Double(percent) / 100))
                    }
                }
                try Task.checkCancellation()
                let app = try await Task.detached { try Self.unpack(zip, in: folder) }.value
                try Self.verify(app, version: version)
                updateLog.notice("Downloaded \(release.tagName, privacy: .public), signed as this copy is")
                show(.downloaded(release, app: app))
            } catch is CancellationError {
                discardDownload()
            } catch {
                updateLog.error("Downloading \(release.tagName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                discardDownload()
                show(error is IntegrityFailure ? .failed("Integrity Check Failed", error.localizedDescription)
                    : .failed("Error Downloading Update", error.localizedDescription))
            }
            download = nil
        }
    }

    private func discardDownload() {
        if let downloadFolder { try? FileManager.default.removeItem(at: downloadFolder) }
        downloadFolder = nil
    }

    struct IntegrityFailure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Unzips the release's zip (as ditto made it) and returns the app in it.
    nonisolated private static func unpack(_ zip: URL, in folder: URL) throws -> URL {
        let unpacked = folder.appendingPathComponent("unpacked")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0,
            let app = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" })
        else { throw IntegrityFailure(message: "The download has no app in it.") }
        return app
    }

    /// The new app must be this one (its bundle id), the release's version, and signed as this copy is:
    /// it satisfies this copy's designated requirement (its identifier and signing certificate), which
    /// is also what keychain access is granted to, so the passwords stay readable after updating.
    nonisolated private static func verify(_ app: URL, version: SoftwareUpdate.Version) throws {
        var me: SecCode?
        var mine: SecStaticCode?
        var requirement: SecRequirement?
        var theirs: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
            SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
            SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement,
            SecStaticCodeCreateWithPath(app as CFURL, [], &theirs) == errSecSuccess, let theirs
        else { throw IntegrityFailure(message: "The update’s signature couldn’t be checked.") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(theirs, flags, requirement)
        guard status == errSecSuccess else {
            throw IntegrityFailure(message: "The update isn’t signed the way this copy of MailMateJ is "
                + "(\(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")), so it can’t replace it.")
        }
        let info = Bundle(url: app)?.infoDictionary ?? [:]
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
            (info["CFBundleShortVersionString"] as? String).flatMap(SoftwareUpdate.Version.init) == version
        else { throw IntegrityFailure(message: "The download isn’t MailMateJ \(version).") }
    }

    // MARK: Installing

    /// Puts the new app in this copy's place, then quits and opens it.
    private func install(_ app: URL) {
        let bundle = Bundle.main.bundleURL
        let folder = bundle.deletingLastPathComponent()
        let readOnly = bundle.path.contains("/AppTranslocation/")
            || (try? folder.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
            || !FileManager.default.isWritableFile(atPath: folder.path)
        guard !readOnly else {
            discardDownload()
            return show(.failed("Read-only File System", "MailMateJ is running on a read-only file system and can therefore not be "
                + "updated. If you downloaded MailMateJ from the internet then moving it out of the Downloads folder should "
                + "solve the problem."))
        }
        do {
            _ = try FileManager.default.replaceItemAt(bundle, withItemAt: app)
        } catch {
            discardDownload()
            return show(.failed("Failed to Install Update", error.localizedDescription))
        }
        discardDownload()
        updateLog.notice("Installed; relaunching")
        // Opens the app once this one has quit (giving up after 10 minutes, if quitting was cancelled).
        let pid = ProcessInfo.processInfo.processIdentifier
        var open = "/usr/bin/open"
        #if DEBUG
            if ProcessInfo.processInfo.environment["MMJ_DEBUG_UPDATE_BACKGROUND"] != nil { open += " -g" }  // not in front
        #endif
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = [
            "-c", "n=0; while /bin/kill -0 \(pid) 2>/dev/null && [ $n -lt 3000 ]; do /bin/sleep 0.2; n=$((n+1)); done; "
                + "/bin/kill -0 \(pid) 2>/dev/null || \(open) \"$0\"", bundle.path,
        ]
        try? relaunch.run()
        window?.close()
        NSApp.terminate(nil)
    }

    // MARK: The window

    private func show(_ stage: UpdateWindowController.Stage) {
        let window = self.window ?? UpdateWindowController { [weak self] action in self?.perform(action) }
        self.window = window
        window.show(stage)
        window.showWindow(nil)
    }

    private func perform(_ action: UpdateWindowController.Action) {
        switch action {
        case .download(let release): startDownload(release)
        case .releaseNotes(let release): NSWorkspace.shared.open(release.htmlURL)
        case .install(let app): install(app)
        case .close: close()
        }
    }

    /// Later, Cancel, OK or the close button: the window goes, with any download.
    private func close() {
        download?.cancel()
        download = nil
        discardDownload()
        let window = self.window
        self.window = nil
        window?.close()
    }

    fileprivate func windowClosed() {
        if window != nil { close() }
    }

    #if DEBUG
        var debugWindow: UpdateWindowController? { window }
    #endif
}

/// The update window, laid out as MailMate's (its constraints, and measured at 2x: 422 pt wide, no title,
/// bold 13 pt title and 12 pt text in a 298 pt column, as tall as they need): the app's icon at 64 pt on
/// the left, the title and text (and a download's progress) beside it, the buttons under them on the right.
@MainActor
final class UpdateWindowController: NSWindowController, NSWindowDelegate {
    enum Stage {
        case upToDate
        case newerThanReleases(SoftwareUpdate.Release)
        case available(SoftwareUpdate.Release)
        case downloading(SoftwareUpdate.Release, fraction: Double)
        case downloaded(SoftwareUpdate.Release, app: URL)
        case failed(String, String)
    }

    enum Action {
        case download(SoftwareUpdate.Release)
        case releaseNotes(SoftwareUpdate.Release)
        case install(URL)
        case close
    }

    private let perform: (Action) -> Void
    private let titleField = NSTextField(wrappingLabelWithString: "")
    private let textField = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let buttons = NSStackView()
    private var actions: [Action] = []
    /// The text's width: MailMate's 298 pt, or more for buttons that need it (the window widens).
    private var contentWidth: NSLayoutConstraint?

    init(perform: @escaping (Action) -> Void) {
        self.perform = perform
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 422, height: 126), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.animationBehavior = .alertPanel  // it pops up as an alert does, as MailMate's
        super.init(window: window)
        window.delegate = self
        build(in: window.contentView!)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build(in view: NSView) {
        let image = NSImageView(image: NSApp.applicationIconImage)
        titleField.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        textField.font = .systemFont(ofSize: 12)
        for field in [titleField, textField] { field.preferredMaxLayoutWidth = 298 }
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        let content = NSStackView(views: [titleField, textField, progress])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.setCustomSpacing(9, after: titleField)  // MailMate's text is 1 pt lower (and as much nearer its buttons)
        progress.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        buttons.orientation = .horizontal
        buttons.spacing = 16  // MailMate's: 16.5 pt between buttons
        let views: [String: NSView] = ["image": image, "content": content, "buttons": buttons]
        for (_, v) in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        contentWidth = content.widthAnchor.constraint(equalToConstant: 298)
        contentWidth?.isActive = true
        for format in [
            "H:|-(24)-[image(==64)]-(16)-[content]-|", "H:[image]-(>=20)-[buttons]-|",
            "V:|-(16)-[image(==64)]-(>=20)-|", "V:|-(16)-[content]-(==19@750,>=19@250)-[buttons]-(18)-|",
        ] {
            view.addConstraints(NSLayoutConstraint.constraints(withVisualFormat: format, metrics: nil, views: views))
        }
    }

    func show(_ stage: Stage) {
        let app = "MailMateJ"
        let running = SoftwareUpdater.shared.current.map { "\(app) \($0)" } ?? app
        func version(_ release: SoftwareUpdate.Release) -> String { "\(app) \(release.version?.description ?? release.tagName)" }
        var buttons: [(String, Action)] = []
        progress.isHidden = true
        switch stage {
        case .upToDate:
            titleField.stringValue = "Up To Date"
            textField.stringValue = "You are running \(running) which is the latest version available."
            buttons = [("OK", .close)]
        case .newerThanReleases(let release):
            titleField.stringValue = "You are Using a Prerelease"
            textField.stringValue = "\(version(release)) is the latest version available. You have version "
                + "\(SoftwareUpdater.shared.current?.description ?? "?")."
            buttons = [("OK", .close)]
        case .available(let release):
            titleField.stringValue = "New Version Available"
            textField.stringValue = "\(version(release)) is now available. You have version "
                + "\(SoftwareUpdater.shared.current?.description ?? "?"). Would you like to download it now?"
            buttons = [("Show release notes", .releaseNotes(release)), ("Later", .close), ("Download", .download(release))]
        case .downloading(let release, let fraction):
            titleField.stringValue = "Downloading \(version(release))"
            textField.stringValue = "\(Int(fraction * 100))% of \(ByteCountFormatter.string(fromByteCount: Int64(release.app?.size ?? 0), countStyle: .file))"
            progress.isHidden = false
            progress.doubleValue = fraction
            buttons = [("Cancel", .close)]
        case .downloaded(let release, let url):
            titleField.stringValue = "Downloaded \(version(release))"
            textField.stringValue = "It’s ready to install. \(app) will quit and open again."
            buttons = [("Later", .close), ("Install & Relaunch", .install(url))]
        case .failed(let title, let text):
            titleField.stringValue = title
            textField.stringValue = text
            buttons = [("OK", .close)]
        }
        defer {
            // MailMate's text has 14 pt lines (a text field's own would be 15).
            let lines = NSMutableParagraphStyle()
            lines.minimumLineHeight = 14
            lines.maximumLineHeight = 14
            textField.attributedStringValue = NSAttributedString(string: textField.stringValue, attributes: [
                .font: textField.font ?? .systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: lines,
            ])
            // The buttons start at least 20 pt after the icon, the text 16 pt after it.
            let width = max(298, self.buttons.fittingSize.width + 4)
            contentWidth?.constant = width
            for field in [titleField, textField] { field.preferredMaxLayoutWidth = width }
            fit()
            if window?.isVisible == false { window?.center() }
        }
        let titles = buttons.map(\.0)
        guard titles != self.buttons.arrangedSubviews.compactMap({ ($0 as? NSButton)?.title }) else {
            actions = buttons.map(\.1)
            return
        }
        for view in self.buttons.arrangedSubviews { view.removeFromSuperview() }
        actions = buttons.map(\.1)
        for (index, (title, _)) in buttons.enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(clicked(_:)))
            button.tag = index
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 86).isActive = true  // MailMate's OK: 85.5 pt
            if index == buttons.count - 1 { button.keyEquivalent = "\r" }
            if title == "Cancel" || title == "Later" { button.keyEquivalent = "\u{1b}" }
            self.buttons.addArrangedSubview(button)
        }
    }

    /// As tall as the stage's text needs, its top staying where it is.
    private func fit() {
        guard let window, let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: view.fittingSize))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if frame != window.frame { window.setFrame(frame, display: window.isVisible) }  // its left edge staying too
    }

    @objc private func clicked(_ sender: NSButton) {
        guard sender.tag < actions.count else { return }
        perform(actions[sender.tag])
    }

    func windowWillClose(_ notification: Notification) {
        SoftwareUpdater.shared.windowClosed()
    }

    #if DEBUG
        var debugText: String { "\(titleField.stringValue) — \(textField.stringValue) [\(buttons.arrangedSubviews.compactMap { ($0 as? NSButton)?.title }.joined(separator: ", "))]" }

        func debugPress(_ title: String) {
            (buttons.arrangedSubviews.first { ($0 as? NSButton)?.title == title } as? NSButton)?.performClick(nil)
        }
    #endif
}
