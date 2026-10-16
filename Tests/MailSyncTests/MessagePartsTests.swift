import Foundation
import JMAPKit
import Testing

@testable import MailSync

@Suite struct MessagePartsTests {
    private func body(_ json: String) throws -> EmailBody {
        try JSONDecoder().decode(EmailBody.self, from: Data(json.utf8))
    }

    @Test func keepsEmbeddedImagesAndAttachmentsButNotTheBody() throws {
        // LinkedIn-style: the HTML body itself has a Content-ID. Calendar invite: an unnamed text/calendar part.
        let email = try body("""
            {"id": "e1", "bodyValues": {},
             "textBody": [{"partId": "1", "blobId": "b1", "type": "text/plain"}],
             "htmlBody": [{"partId": "2", "blobId": "b2", "type": "text/html", "cid": "<body@x>"},
                          {"partId": "3", "blobId": "b3", "type": "image/png", "cid": "<logo@x>"}],
             "attachments": [{"partId": "4", "blobId": "b4", "type": "text/calendar"},
                             {"partId": "5", "blobId": "b5", "type": "application/pdf", "name": "cv.pdf",
                              "disposition": "attachment"}]}
            """)
        #expect(JMAPAccountSync.parts(email).map(\.blobId) == ["b3", "b4", "b5"])
    }
}
