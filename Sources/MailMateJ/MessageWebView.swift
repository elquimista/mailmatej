import AppKit
import WebKit

/// The message web view, plus native handling of the attachment rows: double-click opens, the round
/// buttons, the context menu, and dragging files out.
///
/// Page scripts never run, so the item under the pointer is found with a script in the app's own
/// script world (which the email can't see or affect), as the pointer moves. Items are recognized by the
/// page's token, so an email can't fake one.
final class MessageWebView: WKWebView {
    /// The token of the page on screen; items carrying another token are ignored.
    var token = ""
    var onOpen: (Int) -> Void = { _ in }
    /// A click on one of a row's buttons: the attachment, the button's action and the modifier keys held.
    var onButton: (Int, String, NSEvent.ModifierFlags) -> Void = { _, _, _ in }
    var menuForAttachment: (Int) -> NSMenu? = { _ in nil }
    var onPointerMoved: () -> Void = {}
    var dragItem: (Int) -> NSDraggingItem? = { _ in nil }

    /// The attachment under the pointer, as of the last hit test, and the button under it, if any.
    private(set) var hoveredAttachment: Int?
    private(set) var hoveredButton: String?
    private var hitTestPending = false
    private var hitTestAgain = false
    private var lastPointer = NSPoint.zero
    private var press: (index: Int, button: String?, location: NSPoint)?
    private var dragged = false

    /// Forgets the hovered item (a new page is loading).
    func resetAttachmentTracking() {
        hoveredAttachment = nil
        hoveredButton = nil
        press = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self && $0.userInfo?["mmj"] != nil }) {
            addTrackingArea(NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: ["mmj": true]))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerMoved()
        hitTest(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredAttachment = nil
        hoveredButton = nil
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        hitTest(event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = hoveredAttachment else { return super.mouseDown(with: event) }
        if event.modifierFlags.contains(.control) { return showMenu(index, event) }
        press = (index, hoveredButton, event.locationInWindow)
        dragged = false
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press else { return super.mouseDragged(with: event) }
        guard press.button == nil, !dragged, hypot(event.locationInWindow.x - press.location.x, event.locationInWindow.y - press.location.y) > 3,
            let item = dragItem(press.index)
        else { return }
        dragged = true
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard let press else { return super.mouseUp(with: event) }
        self.press = nil
        if let button = press.button {
            // As a button does: only if the pointer is still on it when released.
            if hoveredAttachment == press.index && hoveredButton == button {
                onButton(press.index, button, event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            }
        } else if !dragged && event.clickCount >= 2 {
            onOpen(press.index)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let index = hoveredAttachment else { return super.rightMouseDown(with: event) }
        showMenu(index, event)
    }

    private func showMenu(_ index: Int, _ event: NSEvent) {
        guard let menu = menuForAttachment(index) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Asks the page which attachment item is at the pointer. One query at a time; a move during a
    /// query triggers one more, so the answer follows the pointer without piling up.
    private func hitTest(_ event: NSEvent) {
        lastPointer = event.locationInWindow
        hitTest()
    }

    private func hitTest() {
        guard !hitTestPending else { return hitTestAgain = true }
        let point = convert(lastPointer, from: nil)
        let y = isFlipped ? point.y : bounds.height - point.y
        hitTestPending = true
        let token = self.token
        callAsyncJavaScript(
            """
            const e = document.elementFromPoint(x, y);
            const item = e && e.closest('mmj-attachments mmj-att');
            const button = e && e.closest('mmj-att mmj-btn');
            return item ? item.getAttribute('data-mmj-att') + (button ? ':' + button.getAttribute('data-mmj-btn') : '') : null;
            """,
            arguments: ["x": point.x, "y": y], in: nil, in: .defaultClient
        ) { [weak self] result in
            guard let self else { return }
            hitTestPending = false
            var hovered: Int?
            var button: String?
            if case .success(let value) = result, let value = value as? String {
                let parts = value.split(separator: ":").map(String.init)
                if parts.count >= 2, parts[0] == token {
                    hovered = Int(parts[1])
                    button = parts.count == 3 ? parts[2] : nil
                }
            }
            if token == self.token {
                hoveredAttachment = hovered
                hoveredButton = button
            }
            if hitTestAgain {
                hitTestAgain = false
                hitTest()
            }
        }
    }
}

extension MessageWebView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}
