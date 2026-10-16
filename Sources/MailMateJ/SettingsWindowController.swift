import AppKit
import MailStore
import SwiftUI

/// The Settings window: toolbar-style tabs like MailMate's preferences. One pane for now.
@MainActor
final class SettingsWindowController: NSWindowController {
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
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// One choice in the Mailbox menu.
struct CounterSource: Identifiable, Hashable {
    let key: String
    let title: String
    let symbol: String
    let depth: Int
    var id: String { key }
}

extension AppModel {
    /// Everything a counter can count, in sidebar order: unified mailboxes, then each account and its mailboxes.
    func counterSources() -> [CounterSource] {
        var sources: [CounterSource] = [
            .init(key: MessageScope.role("inbox").key, title: "Inbox", symbol: "tray", depth: 0),
            .init(key: MessageScope.flagged.key, title: "Flagged", symbol: "flag", depth: 0),
            .init(key: MessageScope.role("drafts").key, title: "Drafts", symbol: "doc", depth: 0),
            .init(key: MessageScope.role("sent").key, title: "Sent Messages", symbol: "paperplane", depth: 0),
            .init(key: MessageScope.role("archive").key, title: "Archive", symbol: "archivebox", depth: 0),
            .init(key: MessageScope.role("junk").key, title: "Junk", symbol: "xmark.bin", depth: 0),
            .init(key: MessageScope.role("trash").key, title: "Deleted Messages", symbol: "trash", depth: 0),
            .init(key: MessageScope.allMessages.key, title: "All Messages", symbol: "tray.full", depth: 0),
        ]
        let boxes = Dictionary(grouping: (try? store.mailboxes()) ?? [], by: \.accountId)
        for account in (try? store.accounts()) ?? [] {
            sources.append(.init(key: MessageScope.account(account.id).key, title: account.name, symbol: "at", depth: 0))
            let children = Dictionary(grouping: boxes[account.id] ?? [], by: { $0.parentRemoteId ?? "" })
            let roleOrder = ["inbox", "drafts", "sent", "archive", "junk", "trash"]
            func add(_ parent: String, depth: Int) {
                let sorted = (children[parent] ?? []).sorted { a, b in
                    let ra = a.role.flatMap(roleOrder.firstIndex) ?? 99
                    let rb = b.role.flatMap(roleOrder.firstIndex) ?? 99
                    return (ra, a.sortOrder, a.name.lowercased()) < (rb, b.sortOrder, b.name.lowercased())
                }
                for box in sorted {
                    sources.append(.init(
                        key: MessageScope.mailbox(box.id).key, title: box.name,
                        symbol: SidebarViewController.symbol(forRole: box.role), depth: depth))
                    add(box.remoteId, depth: depth + 1)
                }
            }
            add("", depth: 1)
        }
        return sources
    }
}

/// Counters pane: pick a corner of the Dock icon, then what it shows.
struct CountersPane: View {
    @ObservedObject private var settings = CounterSettings.shared
    @State private var corner: Corner = .topRight
    @State private var sources: [CounterSource] = AppModel.shared.counterSources()

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(spacing: 10) {
                CornerPicker(selection: $corner, enabled: Set(Corner.allCases.filter { settings.counters[$0]?.showInDock == true }))
                Text("Dock Icon\nCounter Positions")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
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
                        Picker("Mailbox", selection: binding(\.source)) {
                            ForEach(sources) { source in
                                Label(String(repeating: "    ", count: source.depth) + source.title, systemImage: source.symbol)
                                    .tag(source.key)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 240)
                    }
                    GridRow {
                        Text("Count:")
                        Picker("Count", selection: binding(\.unreadOnly)) {
                            Text("Unread").tag(true)
                            Text("All Messages").tag(false)
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
        .onAppear { sources = AppModel.shared.counterSources() }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<CounterConfig, T>) -> Binding<T> {
        Binding(
            get: { settings.counters[corner]![keyPath: keyPath] },
            set: { settings.counters[corner]![keyPath: keyPath] = $0 })
    }
}

/// The app icon with a radio button at each corner; enabled corners show a filled dot.
struct CornerPicker: View {
    @Binding var selection: Corner
    let enabled: Set<Corner>

    var body: some View {
        ZStack {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 64, height: 64)
            ForEach(Corner.allCases) { corner in
                Button { selection = corner } label: {
                    // Selected: radio button with a white center. Others: the corner's badge color if shown in the Dock, grey if not.
                    ZStack {
                        Circle().fill(enabled.contains(corner) || selection == corner
                            ? Color(nsColor: DockTileView.color(for: corner)) : Color.gray.opacity(0.45))
                        if selection == corner {
                            Circle().fill(Color.white).frame(width: 6, height: 6)
                        }
                    }
                    .frame(width: 15, height: 15)
                    .overlay(Circle().strokeBorder(Color.white.opacity(selection == corner ? 0.9 : 0), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .help(corner.title)
                .offset(x: corner == .topLeft || corner == .bottomLeft ? -38 : 38,
                        y: corner == .topLeft || corner == .topRight ? -38 : 38)
            }
        }
        .frame(width: 96, height: 96)
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
