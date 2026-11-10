import AppKit
import MailSync

/// Settings › Software Update, as MailMate's: Watch for (the daily check, and which releases), Ask
/// before downloading updates, and Last check with Check Now (MailMate's Crash reports aren't here).
@MainActor
final class SoftwareUpdatePane: NSViewController {
    private let watch = NSButton(checkboxWithTitle: "Watch for:", target: nil, action: nil)
    private let channel = NSPopUpButton(frame: .zero, pullsDown: false)
    private let ask = NSButton(checkboxWithTitle: "Ask before downloading updates", target: nil, action: nil)
    private let lastCheck = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let checkNow = NSButton(title: "Check Now", target: nil, action: nil)
    private var updater: SoftwareUpdater { .shared }
    private var refresh: Timer?

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Software Update"
    }

    required init?(coder: NSCoder) { fatalError() }

    /// MailMate's pane, measured at 2x: 622 pt wide; labels end at 206.5 pt, controls start at 214; rows
    /// by their text's baseline (from the top): 33, 60, a separator at 83.5, 118 and the button under it;
    /// it ends where MailMate's next separator is (168.5), before its Crash reports.
    override func loadView() {
        let height: CGFloat = 168
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 622, height: height))
        preferredContentSize = view.frame.size
        /// Puts `control` with its drawn left edge at `x` and its text's baseline `baseline` pt from the top.
        func place(_ control: NSView, x: CGFloat, baseline: CGFloat, width: CGFloat? = nil) {
            control.frame.size = control.fittingSize
            if let width { control.frame.size.width = width + control.alignmentRectInsets.left + control.alignmentRectInsets.right }
            let top = baseline - control.firstBaselineOffsetFromTop
            control.frame.origin = NSPoint(x: x - control.alignmentRectInsets.left, y: height - top - control.frame.height)
            view.addSubview(control)
        }
        func label(_ text: String, baseline: CGFloat) {
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            label.frame.size = label.fittingSize
            label.frame.size.width = 200
            label.frame.origin = NSPoint(x: 210 - 200, y: height - (baseline + 1 - label.firstBaselineOffsetFromTop) - label.frame.height)
            view.addSubview(label)
        }
        func separator(at y: CGFloat) {
            let line = SeparatorLine(frame: NSRect(x: 8, y: height - y - 1, width: 606, height: 1))
            view.addSubview(line)
        }
        label("Software update:", baseline: 33)
        watch.target = self
        watch.action = #selector(watchChanged(_:))
        place(watch, x: 214, baseline: 33)
        channel.addItems(withTitles: SoftwareUpdater.Channel.allCases.map(\.title))
        channel.target = self
        channel.action = #selector(channelChanged(_:))
        place(channel, x: 309, baseline: 33, width: 130.5)
        ask.target = self
        ask.action = #selector(askChanged(_:))
        place(ask, x: 214, baseline: 60)
        separator(at: 84)
        label("Last check:", baseline: 117)
        place(lastCheck, x: 214, baseline: 118)
        lastCheck.frame.size.width = 200
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        checkNow.target = self
        checkNow.action = #selector(checkNowClicked(_:))
        place(checkNow, x: 214, baseline: 138)
        spinner.frame = NSRect(x: checkNow.frame.maxX + 4, y: checkNow.frame.midY - 8, width: 16, height: 16)
        view.addSubview(spinner)
        self.view = view
        NotificationCenter.default.addObserver(self, selector: #selector(updaterChanged(_:)), name: SoftwareUpdater.didChange, object: nil)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        update()
        // "5 minutes ago" moves on while it shows.
        refresh = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        refresh?.invalidate()
    }

    private func update() {
        watch.state = updater.watches ? .on : .off
        channel.selectItem(at: SoftwareUpdater.Channel.allCases.firstIndex(of: updater.channel) ?? 0)
        channel.isEnabled = updater.watches
        ask.state = updater.asksBeforeDownloading ? .on : .off
        ask.isEnabled = updater.watches
        if updater.checking {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            lastCheck.stringValue = updater.lastError != nil ? "Failed" : Self.relative(updater.lastCheck)
            lastCheck.toolTip = updater.lastError
        }
        checkNow.isEnabled = !updater.checking
    }

    /// As MailMate says it: Never, Just now, or how long ago.
    static func relative(_ date: Date?) -> String {
        guard let date else { return "Never" }
        if Date().timeIntervalSince(date) < 60 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @objc private func updaterChanged(_ notification: Notification) {
        if isViewLoaded { update() }
    }

    @objc private func watchChanged(_ sender: NSButton) { updater.watches = sender.state == .on }

    @objc private func channelChanged(_ sender: NSPopUpButton) {
        updater.channel = SoftwareUpdater.Channel.allCases[max(0, sender.indexOfSelectedItem)]
    }

    @objc private func askChanged(_ sender: NSButton) { updater.asksBeforeDownloading = sender.state == .on }

    @objc private func checkNowClicked(_ sender: Any?) {
        updater.check(userInitiated: true)
    }
}
