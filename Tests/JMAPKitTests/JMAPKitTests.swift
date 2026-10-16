import Foundation
import Testing

@testable import JMAPKit

@Suite struct JMAPKitTests {
    @Test func requestEncodesBackReferences() throws {
        var request = JMAPRequest()
        let query = request.call("Email/query", ["accountId": "a1", "limit": 10])
        request.call("Email/get", ["accountId": "a1", "#ids": JMAPRequest.ref(query, "/ids")])

        let json = try JSONDecoder().decode(JSONValue.self, from: request.encoded())
        guard case .array(let calls)? = json["methodCalls"], case .array(let get) = calls[1] else {
            Issue.record("bad shape")
            return
        }
        #expect(get[0] == "Email/get")
        #expect(get[1]["#ids"] == ["resultOf": "c0", "name": "Email/query", "path": "/ids"])
        #expect(get[2] == "c1")
        #expect(json["using"] == [.string(Capability.core), .string(Capability.mail)])
    }

    @Test func requestDoesNotEscapeSlashes() throws {
        var request = JMAPRequest()
        request.call("Mailbox/get", ["accountId": "a/b", "ids": nil])
        let body = String(decoding: try request.encoded(), as: UTF8.self)
        #expect(body.contains("\"Mailbox/get\""))
        #expect(body.contains("\"a/b\""))
        #expect(!body.contains("\\/"))
    }

    @Test func responseSurfacesMethodErrors() throws {
        let data = Data("""
            {"methodResponses": [["error", {"type": "cannotCalculateChanges"}, "c0"],
                                 ["Mailbox/get", {"accountId": "a", "state": "s1", "list": [], "notFound": []}, "c1"]],
             "sessionState": "x"}
            """.utf8)
        let response = try JMAPResponse(data: data)
        #expect(throws: JMAPMethodError.self) {
            try response.arguments(CallID(id: "c0", name: "Email/changes"))
        }
        let get = try response.decode(GetResponse<Mailbox>.self, CallID(id: "c1", name: "Mailbox/get"))
        #expect(get.state == "s1")
    }

    @Test func urlTemplatesExpand() {
        let download = Session.expand(
            "https://h/jmap/download/{accountId}/{blobId}/{name}?accept={type}",
            ["accountId": "u1", "blobId": "B/1", "name": "message.eml", "type": "message/rfc822"])
        #expect(download == "https://h/jmap/download/u1/B%2F1/message.eml?accept=message%2Frfc822")

        let es = Session.expand("https://h/es{?types,closeafter,ping}", ["types": "*", "closeafter": "no", "ping": "30"])
        #expect(es == "https://h/es?types=%2A&closeafter=no&ping=30")
    }

    @Test func parsesJMAPDates() {
        #expect(JMAPCoding.parseDate("2014-10-30T14:12:00Z") == Date(timeIntervalSince1970: 1_414_678_320))
        #expect(JMAPCoding.parseDate("2014-10-30T06:12:00-08:00") == Date(timeIntervalSince1970: 1_414_678_320))
        #expect(JMAPCoding.parseDate("2014-10-30T14:12:00.5Z") != nil)
    }

    @Test func sessionURLFromUserInput() {
        #expect(JMAPClient.sessionURL(from: "mail.example.com")?.absoluteString == "https://mail.example.com/.well-known/jmap")
        #expect(JMAPClient.sessionURL(from: "http://localhost:8080")?.absoluteString == "http://localhost:8080/.well-known/jmap")
        #expect(JMAPClient.sessionURL(from: "https://api.fastmail.com/jmap/session")?.absoluteString
            == "https://api.fastmail.com/jmap/session")
    }

    @Test func decodesBlobGet() throws {
        let json: JSONValue = ["accountId": "a", "list": [["id": "B1", "data:asBase64": "aGVsbG8="]], "notFound": ["B2"]]
        let response = try json.decode(BlobGetResponse.self)
        #expect(response.list.first?.data == Data("hello".utf8))
        #expect(response.notFound == ["B2"])
    }

    @Test func eventStreamParser() {
        var parser = EventStreamParser()
        var events: [EventStreamParser.Event] = []
        for byte in Array(": ping\n\nevent: state\ndata: {\"changed\":{}}\r\n\r\n".utf8) {
            if let e = parser.feed(byte) { events.append(e) }
        }
        #expect(events.count == 1)
        #expect(events.first?.type == "state")
        #expect(events.first?.data == "{\"changed\":{}}")
    }

    @Test func rebasesLoopbackSessions() throws {
        let json = Data("""
            {"capabilities": {}, "accounts": {}, "primaryAccounts": {}, "username": "u", "state": "s",
             "apiUrl": "https://mail.test/jmap/", "downloadUrl": "https://mail.test/d/{accountId}/{blobId}",
             "uploadUrl": "https://mail.test/u/{accountId}/", "eventSourceUrl": "https://mail.test/es/?types={types}"}
            """.utf8)
        let session = try JMAPCoding.decoder.decode(Session.self, from: json)
            .rebased(onto: URL(string: "http://localhost:8080/.well-known/jmap")!)
        #expect(session.apiUrl.absoluteString == "http://localhost:8080/jmap/")
        #expect(session.downloadUrl == "http://localhost:8080/d/{accountId}/{blobId}")
        #expect(session.eventSourceUrl == "http://localhost:8080/es/?types={types}")
    }
}
