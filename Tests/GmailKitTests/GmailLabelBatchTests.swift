import Testing

@testable import GmailKit

/// A move takes a message off every other label; Gmail takes 100 label changes a request.
@Suite struct GmailLabelBatchTests {
    @Test func fewLabelsGoInOneRequest() {
        let batches = GmailClient.labelBatches(add: ["TRASH"], remove: ["INBOX", "Label_1"])
        #expect(batches.count == 1)
        #expect(batches[0].add == ["TRASH"])
        #expect(batches[0].remove == ["INBOX", "Label_1"])
    }

    @Test func manyLabelsGoAHundredAtATimeAddedFirst() {
        let remove = (1...165).map { "Label_\($0)" }
        let batches = GmailClient.labelBatches(add: ["TRASH"], remove: remove)
        #expect(batches.map { $0.add.count + $0.remove.count } == [100, 66])
        #expect(batches[0].add == ["TRASH"])
        #expect(batches[1].add.isEmpty)
        #expect(batches.flatMap(\.remove) == remove)
    }

    @Test func noChangeIsStillOneRequest() {
        #expect(GmailClient.labelBatches(add: [], remove: []).count == 1)
    }
}
