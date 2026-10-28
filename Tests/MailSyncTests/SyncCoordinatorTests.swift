import Foundation
import Testing

@testable import MailSync

@Suite struct SyncCoordinatorTests {
    @Test func theTimedCheckLeavesAccountsToWorkingPush() {
        let now = ContinuousClock.now
        func left(signal: Int?, synced: Int?) -> Bool {  // seconds ago
            SyncCoordinator.leftToPush(
                lastSignal: signal.map { now - .seconds($0) }, lastSynced: synced.map { now - .seconds($0) }, now: now)
        }
        #expect(left(signal: 20, synced: 300))  // push pinged lately: it brings the changes
        #expect(!left(signal: 120, synced: 300))  // silent for longer than its pings: checked
        #expect(!left(signal: 20, synced: 1900))  // half an hour since a sync: checked anyway
        #expect(!left(signal: nil, synced: 10))  // no push at all
        #expect(!left(signal: 5, synced: nil))  // not synced yet
    }
}
