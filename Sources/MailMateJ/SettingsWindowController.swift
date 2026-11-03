import AppKit
import MailStore
import SwiftUI

/// The Settings window: toolbar-style tabs in MailMate's preferences' order (its General, Counters, Viewer,
/// Composer, Signatures, Tags, Bundles, Security, Software Update; here Counters and Signatures).
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private let tabs = SettingsTabs()
    private let signatures = SignaturesPane(model: AppModel.shared)

    private init() {
        tabs.tabStyle = .toolbar
        let pane = NSHostingController(rootView: CountersPane())
        pane.sizingOptions = [.preferredContentSize]  // The window takes the pane's size.
        pane.title = "Counters"
        let counters = NSTabViewItem(viewController: pane)
        counters.label = "Counters"
        counters.image = NSImage(systemSymbolName: "envelope.badge", accessibilityDescription: "Counters")
        tabs.addTabViewItem(counters)
        let signaturesItem = NSTabViewItem(viewController: signatures)
        signaturesItem.label = "Signatures"
        signaturesItem.image = NSImage(systemSymbolName: "signature", accessibilityDescription: "Signatures")
        tabs.addTabViewItem(signaturesItem)
        // The pane shown last, by name (an index would move as panes are added).
        let shown = UserDefaults.standard.string(forKey: "SettingsPane")
        tabs.selectedTabViewItemIndex = tabs.tabViewItems.firstIndex { $0.label == shown } ?? 0

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.setFrameAutosaveName("SettingsWindow")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        tabs.paneShown()
    }

    /// Settings › Signatures; with `new`, its editor on that new signature (filled in already).
    func showSignatures(new: SignatureRecord?) {
        showSignaturesPane()
        if let new { signatures.edit(new) }
    }

    private func showSignaturesPane() {
        tabs.selectedTabViewItemIndex = tabs.tabViewItems.firstIndex { $0.viewController === signatures } ?? 0
        show()
    }

    #if DEBUG
        /// Settings › Signatures, editing this signature (nil: a new one).
        func showSignatures(editing signature: SignatureRecord?) {
            showSignaturesPane()
            signatures.edit(signature)
        }
    #endif

    func windowWillClose(_ notification: Notification) {
        AppModel.shared.dockCounters?.isPreviewing = false
    }

    #if DEBUG
        var debugSignaturesPane: SignaturesPane { signatures }
        var debugPaneLabels: [String] { tabs.tabViewItems.map(\.label) }
        func debugSelectPane(_ label: String) {
            if let index = tabs.tabViewItems.firstIndex(where: { $0.label == label }) { tabs.selectedTabViewItemIndex = index }
        }
    #endif
}

/// The panes, titling the window and remembering the one shown; the Dock icon previews the counters
/// while Counters shows. Switching panes is MailMate's (MASPreferences'): the pane goes, the window
/// takes the next one's size (its top left staying, at AppKit's resize speed), then that pane shows.
@MainActor
final class SettingsTabs: NSTabViewController {
    /// Set while the window takes the next pane's size.
    private var resizing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        transitionOptions = []  // no crossfade: the pane shows once the window has its size
    }

    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, willSelect: tabViewItem)
        guard let window = view.window, window.isVisible, let pane = tabViewItem?.viewController else { return }
        let size = pane.preferredContentSize == .zero ? pane.view.fittingSize : pane.preferredContentSize
        let old = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)
        guard frame != old else { return }
        tabView.isHidden = true
        resizing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = window.animationResizeTime(frame)
            window.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            self?.resizing = false
            self?.tabView.isHidden = false
        }
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if !resizing { tabView.isHidden = false }
        UserDefaults.standard.set(tabViewItem?.label, forKey: "SettingsPane")
        paneShown()
    }

    func paneShown() {
        let item = selectedTabViewItemIndex >= 0 ? tabViewItems[selectedTabViewItemIndex] : nil
        view.window?.title = item?.label ?? "Settings"
        AppModel.shared.dockCounters?.isPreviewing = item?.label == "Counters" && view.window?.isVisible == true
    }
}

/// The Dock counter's Mailbox setting: MailMate's mailbox menu (see `MailboxMenu`) in a pull-down.
struct MailboxMenuButton: NSViewRepresentable {
    let roots: [SidebarNode]
    @Binding var selection: String

    func makeCoordinator() -> MailboxMenu { MailboxMenu() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let menu = context.coordinator
        menu.choose = { selection = $0 }
        let signature = selection + "|" + roots.flatMap(\.children).map(\.key).joined(separator: ",")
        guard signature != menu.signature else { return }  // Rebuild only when something changed.
        menu.signature = signature
        button.menu = menu.build(roots: roots, selection: selection)
    }
}

/// Counters pane: pick a corner of the Dock icon, then what it shows.
struct CountersPane: View {
    @ObservedObject private var settings = CounterSettings.shared
    @State private var corner: Corner = .topRight
    @State private var roots = SidebarViewController.currentTree(model: AppModel.shared)

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(spacing: 16) {
                CornerPicker(selection: $corner)
                // 9 pt with 13 pt line pitch, as MailMate draws it (fitted by ink width at 1x).
                Text("Dock Icon\nCounter Positions")
                    .font(.system(size: 9))
                    .lineSpacing(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(white: 0.75))
            }
            .padding(.top, 16)

            GroupBox {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
                    GridRow {
                        Text("Display:").gridColumnAlignment(.trailing)
                        Toggle("In Dock", isOn: binding(\.showInDock))
                    }
                    GridRow {
                        Text("Mailbox:")
                        MailboxMenuButton(roots: roots, selection: binding(\.source))
                            .frame(width: 240)
                    }
                    GridRow {
                        Text("Count:")
                        Picker("Count", selection: binding(\.count)) {
                            ForEach(CountKind.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 240)
                    }
                }
                .padding(14)
                .disabled(false)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { roots = SidebarViewController.currentTree(model: AppModel.shared) }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<CounterConfig, T>) -> Binding<T> {
        Binding(
            get: { settings.counters[corner]![keyPath: keyPath] },
            set: { settings.counters[corner]![keyPath: keyPath] = $0 })
    }
}

/// The app icon with a radio button on each corner, drawn as MailMate draws it (measured at 1x):
/// 14 pt dots centered ±30.5/±32 pt from the icon's center, plain grey; the selected one in the
/// app's accent color (like the other controls in this pane) with a white center.
struct CornerPicker: View {
    @Binding var selection: Corner

    private static let dotGradient = LinearGradient(
        colors: [Color(white: 99 / 255), Color(white: 126 / 255)], startPoint: .top, endPoint: .bottom)

    var body: some View {
        ZStack {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 64, height: 64)
            ForEach(Corner.allCases) { corner in
                Button { selection = corner } label: { dot(selected: selection == corner) }
                    .buttonStyle(.plain)
                    .help(corner.title)
                    .offset(x: corner == .topLeft || corner == .bottomLeft ? -30.5 : 30.5,
                            y: corner == .topLeft || corner == .topRight ? -32 : 32)
            }
        }
        .frame(width: 78, height: 78)
    }

    @ViewBuilder private func dot(selected: Bool) -> some View {
        if selected {
            Circle().fill(Color.accentColor)
                .overlay(Circle().fill(Color.white).frame(width: 6, height: 6))
                .frame(width: 14, height: 14)
        } else {
            Circle().fill(Self.dotGradient).frame(width: 14, height: 14)
        }
    }
}

extension Corner {
    var title: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }
}
