import Foundation
import Testing

@testable import MailStore

@Test func changeQueueKeepsOrderPerAccount() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try MailStore(directory: dir)
    for (account, text) in [("a", "1"), ("b", "x"), ("a", "2"), ("a", "3")] {
        try store.enqueueChange(accountId: account, Data(text.utf8))
    }
    let queued = try store.queuedChanges(accountId: "a")
    #expect(queued.map { String(decoding: $0.change, as: UTF8.self) } == ["1", "2", "3"])
    try store.replaceQueuedChange(id: queued[0].id, with: Data("1b".utf8))
    try store.removeQueuedChange(id: queued[1].id)
    #expect(try store.queuedChanges(accountId: "a").map { String(decoding: $0.change, as: UTF8.self) } == ["1b", "3"])
    #expect(try store.queuedChangeCount(accountId: "b") == 1)
}
