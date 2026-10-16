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

/// MailMate's Mailbox menu: the sidebar's "Mailboxes" and "Sources" sections, with each mailbox
/// that has children opening a submenu. As in MailMate, such a parent can itself be chosen by
/// clicking it, which AppKit doesn't do on its own (see `Coordinator`).
struct MailboxMenuButton: NSViewRepresentable {
    let roots: [SidebarNode]
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.choose = { selection = $0 }
        let signature = selection + "|" + roots.flatMap(\.children).map(\.key).joined(separator: ",")
        guard signature != coordinator.signature else { return }  // Rebuild only when something changed.
        coordinator.signature = signature

        let menu = NSMenu()
        menu.delegate = coordinator
        coordinator.rootMenu = menu
        let titleItem = NSMenuItem(title: "None", action: nil, keyEquivalent: "")  // Pull-down's own title.
        menu.addItem(titleItem)
        for root in roots {
            if root !== roots.first { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: root.title))
            for node in root.children { menu.addItem(item(for: node, coordinator: coordinator, titleItem: titleItem)) }
        }
        button.menu = menu
    }

    private func item(for node: SidebarNode, coordinator: Coordinator, titleItem: NSMenuItem) -> NSMenuItem {
        let item = choice(for: node, coordinator: coordinator, titleItem: titleItem)
        guard !node.children.isEmpty else { return item }
        let submenu = NSMenu()
        submenu.delegate = coordinator
        for child in node.children { submenu.addItem(self.item(for: child, coordinator: coordinator, titleItem: titleItem)) }
        item.submenu = submenu
        return item
    }

    private func choice(for node: SidebarNode, coordinator: Coordinator, titleItem: NSMenuItem) -> NSMenuItem {
        let item = NSMenuItem(title: node.title, action: #selector(Coordinator.chosen(_:)), keyEquivalent: "")
        item.target = coordinator
        item.representedObject = node.scope?.key
        item.image = NSImage(systemSymbolName: node.symbol, accessibilityDescription: nil)
        if node.scope?.key == selection {
            item.state = .on
            titleItem.title = node.title
            titleItem.image = item.image
        }
        return item
    }

    /// Chooses items, including parents of submenus: while the menu is open it follows the
    /// highlighted item and polls the mouse button (menu tracking doesn't hand the app its mouse
    /// events), and a release over a parent item chooses it and closes the menu.
    final class Coordinator: NSObject, NSMenuDelegate {
        var choose: (String) -> Void = { _ in }
        var signature = ""
        weak var rootMenu: NSMenu?
        private var highlighted: NSMenuItem?
        private var timer: Timer?
        private var wasPressed = false

        @objc func chosen(_ sender: NSMenuItem) {
            if let key = sender.representedObject as? String { choose(key) }
        }

        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            highlighted = item
        }

        func menuWillOpen(_ menu: NSMenu) {
            guard menu === rootMenu else { return }
            highlighted = nil
            wasPressed = NSEvent.pressedMouseButtons & 1 != 0  // Still down from the click that opened it.
            let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            RunLoop.current.add(timer, forMode: .common)
            self.timer = timer
        }

        func menuDidClose(_ menu: NSMenu) {
            guard menu === rootMenu else { return }
            timer?.invalidate()
            timer = nil
        }

        private func poll() {
            let pressed = NSEvent.pressedMouseButtons & 1 != 0
            defer { wasPressed = pressed }
            guard wasPressed, !pressed, let item = highlighted, item.hasSubmenu,
                let key = item.representedObject as? String
            else { return }
            rootMenu?.cancelTracking()
            choose(key)
        }
    }
}

/// Counters pane: pick a corner of the Dock icon, then what it shows.
struct CountersPane: View {
    @ObservedObject private var settings = CounterSettings.shared
    @State private var corner: Corner = .topRight
    @State private var roots = SidebarViewController.buildTree(model: AppModel.shared)

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
        .onAppear { roots = SidebarViewController.buildTree(model: AppModel.shared) }
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
