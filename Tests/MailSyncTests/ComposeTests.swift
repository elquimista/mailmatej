import Foundation
import JMAPKit
import MailStore
import Testing

@testable import MailSync

@Suite struct ComposeTests {
    private func a(_ email: String, _ name: String? = nil) -> EmailAddress { EmailAddress(name: name, email: email) }
    private let utc = TimeZone(identifier: "UTC")!
    private let date = Date(timeIntervalSince1970: 1_791_000_000)  // 2026-10-03 04:00:00 GMT

    private func original(
        from: [EmailAddress], replyTo: [EmailAddress] = [], to: [EmailAddress], cc: [EmailAddress] = []
    ) -> Compose.Original {
        Compose.Original(from: from, replyTo: replyTo, to: to, cc: cc, subject: "Plans", date: date, text: "Hi\n\nSee you")
    }

    @Test func replyGoesToSender() {
        let o = original(from: [a("bob@x.test", "Bob")], to: [a("alice@x.test"), a("carol@x.test")])
        let r = Compose.replyRecipients(o, all: false, myAddresses: ["alice@x.test"])
        #expect(r.to == [a("bob@x.test", "Bob")])
        #expect(r.cc.isEmpty)
    }

    @Test func replyPrefersReplyTo() {
        let o = original(from: [a("bob@x.test")], replyTo: [a("list@x.test")], to: [a("alice@x.test")])
        #expect(Compose.replyRecipients(o, all: false, myAddresses: ["alice@x.test"]).to == [a("list@x.test")])
    }

    @Test func replyAllAddsOthersButNotMeOrDuplicates() {
        let o = original(
            from: [a("bob@x.test")], to: [a("Alice@X.test"), a("carol@x.test")],
            cc: [a("dave@x.test"), a("BOB@x.test"), a("alice2@x.test")])
        let r = Compose.replyRecipients(o, all: true, myAddresses: ["alice@x.test", "alice2@x.test"])
        #expect(r.to.map(\.email) == ["bob@x.test"])
        #expect(r.cc.map(\.email) == ["carol@x.test", "dave@x.test"])
    }

    @Test func replyToMyOwnMessageGoesToItsRecipients() {
        let o = original(from: [a("alice@x.test")], to: [a("bob@x.test")], cc: [a("carol@x.test"), a("alice@x.test")])
        let reply = Compose.replyRecipients(o, all: false, myAddresses: ["alice@x.test"])
        #expect(reply.to.map(\.email) == ["bob@x.test"])
        #expect(reply.cc.isEmpty)
        let all = Compose.replyRecipients(o, all: true, myAddresses: ["alice@x.test"])
        #expect(all.cc.map(\.email) == ["carol@x.test"])
    }

    @Test func mailFromMyOtherAccountIsAnsweredLikeAnyoneElses() {
        // Alice and Bob are both my accounts; Bob replies (all) to Alice's message.
        let o = original(from: [a("alice@x.test")], to: [a("bob@x.test"), a("dave@x.test")], cc: [a("carol@x.test")])
        let r = Compose.replyRecipients(
            o, all: true, myAddresses: ["alice@x.test", "bob@x.test", "carol@x.test"], accountAddresses: ["bob@x.test"])
        #expect(r.to.map(\.email) == ["alice@x.test"])
        #expect(r.cc.map(\.email) == ["dave@x.test"])
    }

    @Test func noteToMyselfIsAnsweredToMyself() {
        let o = original(from: [a("alice@x.test")], to: [a("alice@x.test")])
        #expect(Compose.replyRecipients(o, all: false, myAddresses: ["alice@x.test"]).to.map(\.email) == ["alice@x.test"])
    }

    @Test func subjectsDontStackPrefixes() {
        #expect(Compose.replySubject("Plans") == "Re: Plans")
        #expect(Compose.replySubject("RE: Plans") == "RE: Plans")
        #expect(Compose.forwardSubject("Plans") == "Fwd: Plans")
        #expect(Compose.forwardSubject("Fw: Plans") == "Fw: Plans")
    }

    @Test func quotesEveryLine() {
        #expect(Compose.quote("one\n\n> two\nthree\n\n") == "> one\n>\n>> two\n> three")
    }

    @Test func replyDraftQuotesWithAttribution() {
        let o = original(from: [a("bob@x.test", "Bob Builder")], to: [a("alice@x.test")])
        let d = Compose.draft(.reply, original: o, myAddresses: ["alice@x.test"], timeZone: utc)
        #expect(d.subject == "Re: Plans")
        #expect(d.text == "\n\nOn 3 Oct 2026, at 4:00, Bob Builder wrote:\n\n> Hi\n>\n> See you\n")
    }

    @Test func attributionFallsBackToAddress() {
        let o = original(from: [a("bob@x.test")], to: [])
        #expect(Compose.attribution(o, timeZone: utc) == "On 3 Oct 2026, at 4:00, bob@x.test wrote:")
    }

    @Test func forwardDraftIncludesHeaders() {
        let o = original(from: [a("bob@x.test", "Bob")], to: [a("alice@x.test")], cc: [a("carol@x.test")])
        let d = Compose.draft(.forward, original: o, myAddresses: [], timeZone: utc)
        #expect(d.subject == "Fwd: Plans")
        #expect(d.to.isEmpty)
        #expect(d.text == """


            Forwarded message:

            > From: Bob <bob@x.test>
            > To: alice@x.test
            > Cc: carol@x.test
            > Subject: Plans
            > Date: 3 October 2026 at 04:00:00 GMT
            >
            > Hi
            >
            > See you

            """)
    }

    @Test func referencesChainParentReferencesThenMessageId() {
        #expect(Compose.references(messageId: ["<c@x>"], references: ["<a@x>", "<b@x>"], inReplyTo: ["<b@x>"])
            == ["<a@x>", "<b@x>", "<c@x>"])
        #expect(Compose.references(messageId: ["<c@x>"], references: nil, inReplyTo: ["<b@x>"]) == ["<b@x>", "<c@x>"])
        #expect(Compose.references(messageId: ["<c@x>"], references: nil, inReplyTo: nil) == ["<c@x>"])
    }

    @Test func picksTheIdentityTheMessageWasSentTo() {
        let ids = [
            IdentityRecord(accountId: "A", remoteId: "1", name: "Alice", email: "alice@x.test"),
            IdentityRecord(accountId: "A", remoteId: "2", name: "Alice", email: "sales@x.test"),
            IdentityRecord(accountId: "B", remoteId: "3", name: "Bob", email: "bob@x.test"),
        ]
        let o = original(from: [a("carol@x.test")], to: [a("bob@x.test"), a("Sales@x.test")])
        #expect(Compose.identity(replyingTo: o, accountId: "A", identities: ids)?.remoteId == "2")
        let other = original(from: [a("carol@x.test")], to: [a("list@x.test")])
        #expect(Compose.identity(replyingTo: other, accountId: "A", identities: ids)?.remoteId == "1")
    }

    @Test func parsesAndFormatsAddressFields() {
        let parsed = Compose.parseAddresses(#""Doe, Jane" <jane@x.test>, bob@x.test; Carol <carol@x.test>,"#)
        #expect(parsed == [a("jane@x.test", "Doe, Jane"), a("bob@x.test"), a("carol@x.test", "Carol")])
        #expect(Compose.format(parsed) == #""Doe, Jane" <jane@x.test>, bob@x.test, Carol <carol@x.test>"#)
        #expect(Compose.isValid(a("bob@x.test")))
        #expect(!Compose.isValid(a("bob")))
        #expect(!Compose.isValid(a("bob @x.test")))
    }

    @Test func envelopeListsEachRecipientOnce() {
        let m = OutgoingMessage(
            identityId: "1", from: a("alice@x.test"), to: [a("Bob@x.test")], cc: [a("bob@x.test"), a("carol@x.test")],
            bcc: [a("dave@x.test")], subject: "", text: "")
        #expect(m.recipients == ["bob@x.test", "carol@x.test", "dave@x.test"])
    }
}

@Test func addressCompletionsRankPeopleWrittenTo() {
    typealias K = MailStore.KnownAddress
    let known = [
        K(email: "ellie@elliemcgary.com", name: nil, seen: 40, sentTo: 9),
        K(email: "ellie@vastekgroup.com", name: "Ellie", seen: 3, sentTo: 0),
        K(email: "elliemcgary1@gmail.com", name: "Ellie McGary", seen: 12, sentTo: 1),
        K(email: "mcgary@example.com", name: "Dan McGary", seen: 50, sentTo: 0),
        K(email: "bob@example.com", name: "Bob", seen: 99, sentTo: 20),
    ]
    #expect(Compose.completions(for: "ellie", in: known)
        == ["ellie@elliemcgary.com", "Ellie McGary <elliemcgary1@gmail.com>", "Ellie <ellie@vastekgroup.com>"])
    #expect(Compose.completions(for: "McG", in: known) == ["Ellie McGary <elliemcgary1@gmail.com>", "Dan McGary <mcgary@example.com>"])
    // What starts with the typing comes first, even when a word match is written to more.
    let ashley = K(email: "aelliott@trovasearch.com", name: "Ashley Elliott", seen: 80, sentTo: 30)
    #expect(Compose.completions(for: "e", in: known + [ashley]).first == "ellie@elliemcgary.com")
    #expect(Compose.completions(for: "e", in: known + [ashley]).last == "Ashley Elliott <aelliott@trovasearch.com>")
    #expect(Compose.completions(for: "ellie", in: known, excluding: ["ellie@elliemcgary.com"]).count == 2)
    #expect(Compose.completions(for: " ", in: known).isEmpty)
}
