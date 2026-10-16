import AppKit

/// The bar above a message body that says how much remote content was blocked or loaded,
/// with Load and Always Load actions. Like MailMate's, it is orange while content is blocked.
@MainActor
final class RemoteContentBar: NSView {
    var onLoad: (() -> Void)?
    var onAlwaysLoad: ((String) -> Void)?
    var onStopAlwaysLoading: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let loadButton = NSButton(title: "Load", target: nil, action: nil)
    private let alwaysButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let stopButton = NSButton(title: "Stop Always Loading", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for button in [loadButton, stopButton] {
            button.controlSize = .small
            button.bezelStyle = .push
            button.target = self
        }
        loadButton.action = #selector(loadClicked)
        stopButton.action = #selector(stopClicked)
        alwaysButton.controlSize = .small
        alwaysButton.target = self
        alwaysButton.action = #selector(alwaysChosen(_:))

        let stack = NSStackView(views: [label, NSView(), loadButton, alwaysButton, stopButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// - Parameters:
    ///   - sender: the From address, offered for "Always Load".
    ///   - allowedBy: the allow-list entries that made this message load automatically, if any.
    func update(remote: Int, strict: Int, loaded: Bool, sender: String?, allowedBy: [String]) {
        let loadable = remote - strict
        let trackerNote = strict > 0 ? " · \(strict) tracker or insecure resource\(strict == 1 ? "" : "s") always blocked" : ""
        if loaded {
            label.stringValue = "Loaded \(loadable) remote resource\(loadable == 1 ? "" : "s")\(trackerNote)"
            layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
            label.textColor = .secondaryLabelColor
        } else {
            label.stringValue = "Blocked \(remote) remote resource\(remote == 1 ? "" : "s")\(trackerNote)"
            layer?.backgroundColor = NSColor.systemOrange.cgColor
            label.textColor = .black
        }

        loadButton.isHidden = loaded || loadable == 0
        stopButton.isHidden = !(loaded && !allowedBy.isEmpty)
        stopButton.toolTip = allowedBy.isEmpty ? nil : "Allowed: " + allowedBy.joined(separator: ", ")

        alwaysButton.removeAllItems()
        alwaysButton.addItem(withTitle: "Always Load From")
        if let sender, !loaded, loadable > 0 {
            alwaysButton.menu?.addItem(withTitle: sender, action: nil, keyEquivalent: "").representedObject = sender
            if let domain = sender.split(separator: "@").last {
                alwaysButton.menu?.addItem(withTitle: "Anyone at \(domain)", action: nil, keyEquivalent: "")
                    .representedObject = "@\(domain)"
            }
            alwaysButton.isHidden = false
        } else {
            alwaysButton.isHidden = true
        }
    }

    @objc private func loadClicked() { onLoad?() }

    @objc private func stopClicked() { onStopAlwaysLoading?() }

    @objc private func alwaysChosen(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? String else { return }
        onAlwaysLoad?(value)
    }
}
