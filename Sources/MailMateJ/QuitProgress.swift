import AppKit

/// Quitting while changes are still on their way to the servers, as MailMate does it: a small window shows
/// how many are left with a progress bar, and the app quits by itself once they're done, so none is cut
/// off half done. "Quit Now" quits at once (a hung server); whatever was cut off is set right from the
/// servers on the next launch.
@MainActor
final class QuitProgress: NSObject {
    private static var current: QuitProgress?

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let reply: (Bool) -> Void
    private let total: Int

    /// Waits for `model`'s server work before quitting; `reply` answers the app's terminate request.
    static func wait(for model: AppModel, reply: @escaping (Bool) -> Void) {
        guard model.pendingWork > 0 else { return reply(true) }
        let progress = QuitProgress(model: model, reply: reply)
        current = progress
        progress.panel.center()
        progress.panel.makeKeyAndOrderFront(nil)
        #if DEBUG
            NSLog("MMJ quit: progress shown, window \(progress.panel.windowNumber) frame \(NSStringFromRect(progress.panel.frame)) visible \(progress.panel.isVisible)")
        #endif
        model.whenNoPendingWork {
            #if DEBUG
                NSLog("MMJ quit: changes done, quitting")
            #endif
            progress.finish(quit: true)
        }
    }

    private init(model: AppModel, reply: @escaping (Bool) -> Void) {
        self.reply = reply
        total = max(model.pendingWork, 1)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 118), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = "Quitting MailMateJ"
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false  // also when quitting from the Dock with another app in front

        label.font = .systemFont(ofSize: 13)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(total)
        let quitNow = NSButton(title: "Quit Now", target: self, action: #selector(quitNow(_:)))
        quitNow.keyEquivalent = "\u{1B}"
        for view in [label, bar, quitNow] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            panel.contentView?.addSubview(view)
        }
        guard let content = panel.contentView else { return }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            quitNow.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12),
            quitNow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            quitNow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        show(model.pendingWork)
        model.onPendingWorkChange = { [weak self] left in self?.show(left) }
    }

    private func show(_ left: Int) {
        label.stringValue = left == 1 ? "Finishing 1 change on the server…" : "Finishing \(left) changes on the servers…"
        bar.doubleValue = Double(total - min(left, total))
    }

    @objc private func quitNow(_ sender: Any?) { finish(quit: true) }

    private func finish(quit: Bool) {
        guard Self.current === self else { return }
        Self.current = nil
        AppModel.shared?.onPendingWorkChange = nil
        panel.orderOut(nil)
        // A message that couldn't be sent meanwhile is back in its window: stay, so it can be seen.
        reply(quit && !ComposeWindowController.hasUnsentWindow)
    }
}
