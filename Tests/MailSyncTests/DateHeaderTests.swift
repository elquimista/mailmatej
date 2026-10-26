import Testing

@testable import MailSync

@Suite struct DateHeaderZoneTests {
    @Test func zonesAreReadFromDateHeaders() {
        #expect(JMAPAccountSync.zone(ofDateHeader: "Mon, 26 Oct 2026 09:27:08 +0200") == 120)
        #expect(JMAPAccountSync.zone(ofDateHeader: "Mon, 26 Oct 2026 09:27:08 -0530 (IST)") == -330)
        #expect(JMAPAccountSync.zone(ofDateHeader: "Mon, 26 Oct 2026 09:27:08 GMT") == nil)
        #expect(JMAPAccountSync.zone(ofDateHeader: nil) == nil)
    }
}
