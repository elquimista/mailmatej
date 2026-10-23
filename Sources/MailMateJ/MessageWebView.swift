import AppKit
import WebKit

/// The message's web view. It shows only the message content and never scrolls up and down itself:
/// it's as tall as the content, inside the message's native scroll view (under the native headers), so
/// vertical scrolling and the paging keys go to that scroll view; wide content still scrolls sideways
/// here.
///
/// Page scripts never run, so the link under the pointer is found with a script in the app's own script
/// world (which the email can't see or affect), as the pointer moves, for the link preview.
final class MessageWebView: WKWebView {
    var onPointerMoved: () -> Void = {}
    /// The link under the pointer changed (its href, or nil when off links), for the URL preview.
    var onHoverLink: (String?) -> Void = { _ in }

    private(set) var hoveredLink: String? {
        didSet { if hoveredLink != oldValue { onHoverLink(hoveredLink) } }
    }
    private var hitTestPending = false
    private var hitTestAgain = false
    private var lastPointer = NSPoint.zero
    /// The axis a trackpad gesture started on, kept for the whole gesture and its momentum.
    private var verticalGesture = true

    /// Forgets the hovered link (a new page is loading).
    func resetHover() {
        hoveredLink = nil
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
        hoveredLink = nil
    }

    /// Up and down go straight to the message's scroll view (no round trip through WebKit, so it
    /// follows the fingers); sideways stays here, for wide content.
    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began || event.phase == .mayBegin || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            verticalGesture = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
        }
        if verticalGesture, let scroll = enclosingScrollView {
            scroll.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
        hitTest(event)
    }

    /// The paging keys scroll the message's scroll view.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty, let scroll = enclosingScrollView as? MessageScrollView else { return super.keyDown(with: event) }
        let shift = event.modifierFlags.contains(.shift)
        switch (event.specialKey, event.charactersIgnoringModifiers) {
        case (_, " "?): scroll.page(shift ? -1 : 1)
        case (.pageDown?, _): scroll.page(1)
        case (.pageUp?, _): scroll.page(-1)
        case (.home?, _): scroll.toEdge(top: true)
        case (.end?, _): scroll.toEdge(top: false)
        case (.downArrow?, _): scroll.line(1)
        case (.upArrow?, _): scroll.line(-1)
        default: super.keyDown(with: event)
        }
    }

    private func hitTest(_ event: NSEvent) {
        lastPointer = event.locationInWindow
        hitTest()
    }

    /// Asks the page which link is at the pointer. One query at a time; a move during a query triggers
    /// one more, so the answer follows the pointer without piling up.
    private func hitTest() {
        guard !hitTestPending else { return hitTestAgain = true }
        let point = convert(lastPointer, from: nil)
        let y = isFlipped ? point.y : bounds.height - point.y
        hitTestPending = true
        callAsyncJavaScript(
            """
            const e = document.elementFromPoint(x / zoom, y / zoom);
            const link = e && e.closest('a[href]');
            return link ? link.getAttribute('href').trim() : null;
            """,
            arguments: ["x": point.x, "y": y, "zoom": magnification], in: nil, in: .defaultClient
        ) { [weak self] result in
            guard let self else { return }
            hitTestPending = false
            hoveredLink = (try? result.get()) as? String
            if hitTestAgain {
                hitTestAgain = false
                hitTest()
            }
        }
    }
}

#if DEBUG
    extension MessageWebView {
        /// Hit-tests the middle of the first link whose text contains `text`, as a pointer move there would.
        func debugHoverLink(containing text: String) async {
            let result = try? await callAsyncJavaScript(
                """
                const a = [...document.querySelectorAll('a')].find(a => a.textContent.includes(t));
                if (!a) return null;
                const b = a.getBoundingClientRect();
                return [b.x + b.width / 2, b.y + b.height / 2];
                """, arguments: ["t": text], in: nil, contentWorld: .defaultClient)
            guard let point = result as? [Double], point.count == 2 else { return NSLog("MMJ hover: no link \(text)") }
            lastPointer = convert(NSPoint(x: point[0] * magnification, y: isFlipped ? point[1] * magnification : bounds.height - point[1] * magnification), to: nil)
            hitTest()
        }
    }
#endif
