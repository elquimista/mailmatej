import Foundation
import MailStore
import MailSync
import WebKit

/// Serves `mmj-cid://<messageId>/<content-id>` to the message web view: embedded images and other
/// parts of the message itself, from the local cache or downloaded from the server. No remote
/// content is involved, so these always load.
@MainActor
final class EmbeddedPartSchemeHandler: NSObject, WKURLSchemeHandler {
    private let model: AppModel
    private var stopped = Set<ObjectIdentifier>()

    /// Only parts of the messages on screen are served, so one message's HTML can't pull in another's
    /// (in a stack of several, the others shown with it).
    var allowedMessageIDs: Set<Int64> = []

    /// The one message on screen.
    var allowedMessageID: Int64? {
        get { allowedMessageIDs.first }
        set { allowedMessageIDs = newValue.map { [$0] } ?? [] }
    }

    init(model: AppModel) {
        self.model = model
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        guard let url = task.request.url, let messageId = url.host.flatMap(Int64.init), allowedMessageIDs.contains(messageId)
        else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let cid = String(url.path.dropFirst())
        Task {
            defer { stopped.remove(id) }
            do {
                guard let (accountId, part) = try model.store.part(messageId: messageId, cid: cid) else {
                    throw URLError(.fileDoesNotExist)
                }
                let data = try await model.partData(accountId: accountId, part: part)
                guard !stopped.contains(id) else { return }
                task.didReceive(URLResponse(url: url, mimeType: part.type, expectedContentLength: data.count, textEncodingName: nil))
                task.didReceive(data)
                task.didFinish()
            } catch {
                guard !stopped.contains(id) else { return }
                task.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }
}
