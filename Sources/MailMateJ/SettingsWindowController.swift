import AppKit
import MailStore
import SwiftUI

/// The Settings window: toolbar-style tabs like MailMate's preferences. One pane for now.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let pane = NSHostingController(rootView: CountersPane())
        pane.sizingOptions = [.preferredContentSize]  // The window takes the pane's size.
        let counters = NSTabViewItem(viewController: pane)
        counters.label = "Counters"
        counters.image = NSImage(systemSymbolName: "envelope.badge", accessibilityDescription: "Counters")
        tabs.addTabViewItem(counters)

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = "Counters"
        window.setFrameAutosaveName("SettingsWindow")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        AppModel.shared.dockCounters?.isPreviewing = true  // Counters is the only pane.
    }

    func windowWillClose(_ notification: Notification) {
        AppModel.shared.dockCounters?.isPreviewing = false
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
