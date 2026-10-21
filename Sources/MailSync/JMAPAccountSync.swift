import Foundation
import JMAPKit
import MailStore

/// Keeps one JMAP account in sync with the local store, using state strings and `/changes`.
public actor JMAPAccountSync {
    public let account: AccountRecord
    private let client: JMAPClient
    private let store: MailStore
    private var lastIdentitySync: Date?

    public init(account: AccountRecord, credentials: Credentials, store: MailStore, urlSession: URLSession = .shared)
        throws
    {
        guard let url = URL(string: account.sessionURL) else { throw JMAPError.invalidResponse("bad session URL") }
        self.account = account
        self.client = JMAPClient(sessionURL: url, credentials: credentials, urlSession: urlSession)
        self.store = store
    }

    public struct Result: Sendable {
        public var mailboxes = 0
        public var created = 0
        public var updated = 0
        public var destroyed = 0
        /// Messages that arrived since the last sync (from `/changes`, never the first full sync): what
        /// rules run on.
        public var arrived: [String] = []
    }

    /// One full sync round: mailboxes, identities, then emails.
    @discardableResult
    public func sync() async throws -> Result {
        let session = try await client.currentSession()
        let accountId = try remoteAccountId(session)
        syncLog.notice(
            "Syncing \(self.account.name, privacy: .public): api \(session.apiUrl.absoluteString, privacy: .public), account \(accountId, privacy: .public)")
        var result = Result()
        result.mailboxes = try await syncMailboxes(accountId)
        if session.supports(Capability.submission), lastIdentitySync.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
            try await syncIdentities(accountId)
            lastIdentitySync = Date()
        }
        try await syncEmails(accountId, session: session, into: &result)
        try await fillInReferences(accountId)
        try await fillInRecipientGroups(accountId)
        return result
    }

    /// Fetches and stores the body of one message (and its raw .eml). Called when a message is opened.
    public func fetchBody(messageId: Int64) async throws -> MessageBody {
        guard let detail = try store.detail(id: messageId) else { throw JMAPError.invalidResponse("unknown message") }
        let session = try await client.currentSession()
        let accountId = try remoteAccountId(session)

        var request = JMAPRequest()
        let get = request.call("Email/get", [
            "accountId": .string(accountId),
            "ids": .strings([detail.remoteId]),
            "properties": .strings(EmailBody.properties),
            "fetchTextBodyValues": true,
            "fetchHTMLBodyValues": true,
        ])
        async let raw = try? client.download(
            accountId: accountId, blobId: detail.blobId, type: "message/rfc822", name: "message.eml")
        let response = try await client.send(request)
        guard let email = try response.decode(GetResponse<EmailBody>.self, get).list.first else {
            throw JMAPError.invalidResponse("message no longer exists on the server")
        }
        let body = Self.render(email)
        try store.saveBody(messageId: messageId, body, parts: Self.parts(email))
        if let data = await raw, (try? store.blobs.write(data, accountId: account.id, blobId: detail.blobId)) != nil {
            try store.setDownloadState(1, messageIds: [messageId])
        }
        return body
    }

    public struct DownloadBatchResult: Sendable {
        /// Messages handled in this batch (downloaded or given up on); 0 means nothing is left.
        public var processed: Int
        public var failed: Int
    }

    /// Downloads the next messages not yet stored locally, newest first: body text, HTML and parts
    /// (searchable, instant to open) and the raw .eml. Messages up to 512 KB come in batched
    /// Blob/get requests where the server supports them; larger ones are downloaded one by one.
    public func downloadNextBatch(limit: Int = 25) async throws -> DownloadBatchResult {
        let pending = try store.pendingDownloads(accountId: account.id, limit: limit)
        guard !pending.isEmpty else { return DownloadBatchResult(processed: 0, failed: 0) }
        let session = try await client.currentSession()
        let accountId = try remoteAccountId(session)
        var failed = Set<Int64>()

        // Bodies, all in one request.
        let needBody = pending.filter { !$0.hasBody }
        if !needBody.isEmpty {
            var request = JMAPRequest()
            let get = request.call("Email/get", [
                "accountId": .string(accountId),
                "ids": .strings(needBody.map(\.remoteId)),
                "properties": .strings(EmailBody.properties),
                "fetchTextBodyValues": true,
                "fetchHTMLBodyValues": true,
                "maxBodyValueBytes": 2_000_000,
            ])
            let result = try await client.send(request).decode(GetResponse<EmailBody>.self, get)
            let ids = Dictionary(needBody.map { ($0.remoteId, $0.id) }, uniquingKeysWith: { a, _ in a })
            for email in result.list {
                if let id = ids[email.id] { try store.saveBody(messageId: id, Self.render(email), parts: Self.parts(email)) }
            }
            for gone in result.notFound ?? [] { if let id = ids[gone] { failed.insert(id) } }
        }

        // Raw messages.
        let needRaw = pending.filter { !failed.contains($0.id) && !store.blobs.contains(accountId: account.id, blobId: $0.blobId) }
        var oneByOne = needRaw
        if session.supports(Capability.blob) {
            let small = needRaw.filter { $0.size <= 512_000 }
            oneByOne = needRaw.filter { $0.size > 512_000 }
            for group in Self.groups(small, maxBytes: 4_000_000) {
                var request = JMAPRequest(using: [Capability.core, Capability.mail, Capability.blob])
                let blobIds = Array(Set(group.map(\.blobId)))
                let get = request.call("Blob/get", [
                    "accountId": .string(accountId), "ids": .strings(blobIds), "properties": ["data:asBase64"],
                ])
                let result = try await client.send(request).decode(BlobGetResponse.self, get)
                var written = Set<String>()
                for blob in result.list {
                    guard let data = blob.data, blob.isTruncated != true else { continue }
                    try store.blobs.write(data, accountId: account.id, blobId: blob.id)
                    written.insert(blob.id)
                }
                for item in group where !written.contains(item.blobId) { failed.insert(item.id) }
            }
        }
        for item in oneByOne {
            do {
                let data = try await client.download(
                    accountId: accountId, blobId: item.blobId, type: "message/rfc822", name: "message.eml")
                try store.blobs.write(data, accountId: account.id, blobId: item.blobId)
            } catch JMAPError.http(status: 404, _, _) {
                failed.insert(item.id)
            }
        }

        try store.setDownloadState(1, messageIds: pending.map(\.id).filter { !failed.contains($0) })
        try store.setDownloadState(2, messageIds: Array(failed))
        return DownloadBatchResult(processed: pending.count, failed: failed.count)
    }

    /// Splits downloads into groups whose sizes add up to at most `maxBytes` (at least one per group).
    static func groups(_ items: [MailStore.PendingDownload], maxBytes: Int) -> [[MailStore.PendingDownload]] {
        var groups: [[MailStore.PendingDownload]] = []
        var current: [MailStore.PendingDownload] = []
        var bytes = 0
        for item in items {
            if !current.isEmpty && bytes + item.size > maxBytes {
                groups.append(current)
                current = []
                bytes = 0
            }
            current.append(item)
            bytes += item.size
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Downloads one blob (e.g. an embedded image part).
    public func downloadBlob(blobId: String, type: String, name: String) async throws -> Data {
        let accountId = try remoteAccountId(try await client.currentSession())
        return try await client.download(accountId: accountId, blobId: blobId, type: type, name: name)
    }

    public enum PushTransport: String, Sendable {
        case webSocket = "WebSocket"
        case eventSource = "EventSource"
    }

    public enum PushSignal: Sendable {
        /// Something changed in this account.
        case changed
        /// The connection is alive (a ping, or a change in another account).
        case alive
    }

    public func supportsWebSocketPush() async -> Bool {
        (try? await client.currentSession())?.webSocketURL != nil
    }

    /// Push for this account over `transport`, until cancelled or the connection fails.
    public func pushSignals(_ transport: PushTransport) async throws -> AsyncThrowingStream<PushSignal, Error> {
        let session = try await client.currentSession()
        let accountId = try remoteAccountId(session)
        let signals =
            switch transport {
            case .webSocket: try await client.webSocketSignals()
            case .eventSource: try await client.eventSourceSignals()
            }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await signal in signals {
                        if case .changed(let change) = signal, change.changed[accountId] != nil {
                            continuation.yield(.changed)
                        } else {
                            continuation.yield(.alive)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Mailboxes

    private func syncMailboxes(_ accountId: String) async throws -> Int {
        if let since = try store.syncState(accountId: account.id, type: "Mailbox") {
            do {
                return try await syncMailboxChanges(accountId, since: since)
            } catch let error as JMAPMethodError where error.type == "cannotCalculateChanges" {
                // Fall through to a full refresh.
            }
        }
        var request = JMAPRequest()
        let get = request.call("Mailbox/get", ["accountId": .string(accountId), "ids": .null])
        let response = try await client.send(request)
        let result = try response.decode(GetResponse<Mailbox>.self, get)
        try store.applyMailboxes(
            accountId: account.id, upserts: result.list.map(Self.incoming), destroyed: [], replaceAll: true)
        try store.setSyncState(result.state, accountId: account.id, type: "Mailbox")
        return result.list.count
    }

    private func syncMailboxChanges(_ accountId: String, since: String) async throws -> Int {
        var state = since
        var count = 0
        while true {
            var request = JMAPRequest()
            let changes = request.call("Mailbox/changes", ["accountId": .string(accountId), "sinceState": .string(state)])
            let created = request.call("Mailbox/get", [
                "accountId": .string(accountId), "#ids": JMAPRequest.ref(changes, "/created"),
            ])
            let updated = request.call("Mailbox/get", [
                "accountId": .string(accountId), "#ids": JMAPRequest.ref(changes, "/updated"),
            ])
            let response = try await client.send(request)
            let delta = try response.decode(ChangesResponse.self, changes)
            let upserts =
                try response.decode(GetResponse<Mailbox>.self, created).list
                + response.decode(GetResponse<Mailbox>.self, updated).list
            try store.applyMailboxes(
                accountId: account.id, upserts: upserts.map(Self.incoming), destroyed: delta.destroyed,
                replaceAll: false)
            try store.setSyncState(delta.newState, accountId: account.id, type: "Mailbox")
            count += upserts.count + delta.destroyed.count
            state = delta.newState
            if !delta.hasMoreChanges { return count }
        }
    }

    // MARK: Identities

    /// Asks the server for a sending identity for each address it doesn't have one for yet
    /// (Identity/set create), then stores the server's identities. Returns the addresses the server
    /// refused, with its reason (servers usually only allow addresses that belong to the login).
    public func ensureIdentities(_ addresses: [String], name: String) async throws -> [(email: String, reason: String)] {
        let session = try await client.currentSession()
        guard session.supports(Capability.submission) else { throw JMAPError.missingCapability(Capability.submission) }
        let accountId = try remoteAccountId(session)
        var request = JMAPRequest(using: [Capability.core, Capability.mail, Capability.submission])
        let get = request.call("Identity/get", ["accountId": .string(accountId), "ids": .null])
        let existing = Set(try await client.send(request).decode(GetResponse<Identity>.self, get).list.map { $0.email.lowercased() })
        let missing = addresses.map { $0.lowercased() }.filter { !existing.contains($0) }
        var refused: [(String, String)] = []
        if !missing.isEmpty {
            var create = JMAPRequest(using: [Capability.core, Capability.mail, Capability.submission])
            let set = create.call("Identity/set", [
                "accountId": .string(accountId),
                "create": .object(Dictionary(uniqueKeysWithValues: missing.enumerated().map { index, email in
                    ("i\(index)", JSONValue.object(["email": .string(email), "name": .string(name)]))
                })),
            ])
            let result = try await client.send(create).arguments(set)
            for (index, email) in missing.enumerated() {
                if let error = result["notCreated"]?["i\(index)"] { refused.append((email, Self.setErrorText(error))) }
            }
        }
        try await syncIdentities(accountId)
        lastIdentitySync = Date()
        return refused
    }

    private func syncIdentities(_ accountId: String) async throws {
        var request = JMAPRequest(using: [Capability.core, Capability.mail, Capability.submission])
        let get = request.call("Identity/get", ["accountId": .string(accountId), "ids": .null])
        let response = try await client.send(request)
        let identities = try response.decode(GetResponse<Identity>.self, get).list
        try store.replaceIdentities(accountId: account.id, identities.map { ($0.id, $0.name, $0.email) })
    }

    // MARK: Emails

    private func syncEmails(_ accountId: String, session: Session, into result: inout Result) async throws {
        let pageSize = min(session.maxObjectsInGet, 500)
        if let since = try store.syncState(accountId: account.id, type: "Email") {
            do {
                try await syncEmailChanges(accountId, since: since, pageSize: pageSize, into: &result)
                return
            } catch let error as JMAPMethodError where error.type == "cannotCalculateChanges" {
                // Server can't give a delta (state too old): fall back to a full sync.
            }
        }
        try await initialEmailSync(accountId, pageSize: pageSize, into: &result)
    }

    /// Pages through every email, newest first. The state captured on the first page is
    /// saved at the end; anything that changes meanwhile is picked up by the next `/changes`.
    private func initialEmailSync(_ accountId: String, pageSize: Int, into result: inout Result) async throws {
        var anchor: String?
        var position = 0
        var firstState: String?
        var seen = Set<String>()

        while true {
            var queryArgs: [String: JSONValue] = [
                "accountId": .string(accountId),
                "sort": [["property": "receivedAt", "isAscending": false]],
                "limit": .number(Double(pageSize)),
            ]
            if let anchor {
                queryArgs["anchor"] = .string(anchor)
                queryArgs["anchorOffset"] = 1
            } else {
                queryArgs["position"] = .number(Double(position))
            }
            var request = JMAPRequest()
            let query = request.call("Email/query", queryArgs)
            let get = request.call("Email/get", [
                "accountId": .string(accountId),
                "#ids": JMAPRequest.ref(query, "/ids"),
                "properties": .strings(Email.properties),
            ])

            let response: JMAPResponse
            let ids: [String]
            do {
                response = try await client.send(request)
                ids = try response.decode(QueryResponse.self, query).ids
            } catch let error as JMAPMethodError where error.type == "anchorNotFound" {
                // The anchor email was deleted mid-sync; continue by position instead.
                anchor = nil
                position = seen.count
                continue
            }
            let page = try response.decode(GetResponse<Email>.self, get)
            if firstState == nil { firstState = page.state }

            try store.upsertMessages(accountId: account.id, page.list.map(Self.incoming))
            for email in page.list where seen.insert(email.id).inserted { result.created += 1 }

            if ids.count < pageSize { break }
            anchor = ids.last
        }
        if let firstState {
            try store.setSyncState(firstState, accountId: account.id, type: "Email")
        }
    }

    private func syncEmailChanges(_ accountId: String, since: String, pageSize: Int, into result: inout Result)
        async throws
    {
        var state = since
        while true {
            var request = JMAPRequest()
            let changes = request.call("Email/changes", [
                "accountId": .string(accountId), "sinceState": .string(state), "maxChanges": .number(Double(pageSize)),
            ])
            let created = request.call("Email/get", [
                "accountId": .string(accountId), "#ids": JMAPRequest.ref(changes, "/created"),
                "properties": .strings(Email.properties),
            ])
            let updated = request.call("Email/get", [
                "accountId": .string(accountId), "#ids": JMAPRequest.ref(changes, "/updated"),
                "properties": .strings(Email.properties),
            ])
            let response = try await client.send(request)
            let delta = try response.decode(ChangesResponse.self, changes)
            let createdEmails = try response.decode(GetResponse<Email>.self, created).list
            let updatedEmails = try response.decode(GetResponse<Email>.self, updated).list

            try store.upsertMessages(accountId: account.id, (createdEmails + updatedEmails).map(Self.incoming))
            try store.deleteMessages(accountId: account.id, remoteIds: delta.destroyed)
            try store.setSyncState(delta.newState, accountId: account.id, type: "Email")

            result.created += createdEmails.count
            result.arrived += createdEmails.map(\.id)
            result.updated += updatedEmails.count
            result.destroyed += delta.destroyed.count
            state = delta.newState
            if !delta.hasMoreChanges { return }
        }
    }

    /// References of messages stored before they were kept (once, 500 per request): threads are built
    /// from reply headers.
    private func fillInReferences(_ accountId: String) async throws {
        while true {
            let missing = try store.remoteIDsMissingReferences(accountId: account.id, limit: 500)
            guard !missing.isEmpty else { return }
            var request = JMAPRequest()
            let get = request.call("Email/get", [
                "accountId": .string(accountId), "ids": .strings(missing), "properties": ["id", "references"],
            ])
            struct Refs: Decodable { let id: String; let references: [String]? }
            let list = try await client.send(request).decode(GetResponse<Refs>.self, get).list
            var found: [String: [String]] = Dictionary(uniqueKeysWithValues: missing.map { ($0, []) })  // gone ones too
            for email in list { found[email.id] = email.references ?? [] }
            try store.setReferences(accountId: account.id, found)
            if missing.count < 500 { return }
        }
    }

    /// Recipient groups of messages stored before they were kept (once, 500 per request): only
    /// messages with no To or Cc address can have an empty group worth showing.
    private func fillInRecipientGroups(_ accountId: String) async throws {
        while true {
            let missing = try store.remoteIDsMissingRecipientGroups(accountId: account.id, limit: 500)
            guard !missing.isEmpty else { return }
            var request = JMAPRequest()
            let get = request.call("Email/get", [
                "accountId": .string(accountId), "ids": .strings(missing),
                "properties": .strings(["id", Email.groupedTo, Email.groupedCc]),
            ])
            struct Groups: Decodable {
                let id: String
                let to: [EmailAddressGroup]?
                let cc: [EmailAddressGroup]?
                enum CodingKeys: String, CodingKey { case id, to = "header:To:asGroupedAddresses", cc = "header:Cc:asGroupedAddresses" }
            }
            let list = try await client.send(request).decode(GetResponse<Groups>.self, get).list
            var found: [String: [IncomingMessage.Address]] = Dictionary(uniqueKeysWithValues: missing.map { ($0, []) })
            for email in list { found[email.id] = Self.groupNames(email.to, .toGroup) + Self.groupNames(email.cc, .ccGroup) }
            try store.addRecipientGroups(accountId: account.id, found)
            if missing.count < 500 { return }
        }
    }

    // MARK: Changes

    /// Applies one patch to every email (Email/set update), e.g. `["keywords/$seen": true]` or
    /// `["mailboxIds": {archive: true}]`. Emails the server didn't change are fetched again, so the
    /// local copy (already changed by the caller) shows the server's state, and an error is thrown.
    public func update(remoteIds: [String], patch: [String: JSONValue]) async throws {
        guard !remoteIds.isEmpty else { return }
        let accountId = try remoteAccountId(try await client.currentSession())
        var request = JMAPRequest()
        let set = request.call("Email/set", [
            "accountId": .string(accountId),
            "update": .object(Dictionary(uniqueKeysWithValues: remoteIds.map { ($0, JSONValue.object(patch)) })),
        ])
        let failed: [String]
        do {
            failed = Array(try await client.send(request).arguments(set)["notUpdated"]?.objectValue?.keys ?? [:].keys)
        } catch {
            try? await refetch(remoteIds, accountId)
            throw error
        }
        guard failed.isEmpty else {
            try? await refetch(failed, accountId)
            throw JMAPError.invalidResponse("the server didn’t change \(failed.count) message\(failed.count == 1 ? "" : "s")")
        }
    }

    /// Creates a top-level mailbox (Mailbox/set), with `role` if the server accepts it, and syncs the
    /// mailbox list so it's in the store.
    public func createMailbox(name: String, role: String?, parentRemoteId: String? = nil) async throws {
        let accountId = try remoteAccountId(try await client.currentSession())
        func create(withRole: Bool) async throws -> JSONValue? {
            var mailbox: [String: JSONValue] = ["name": .string(name), "parentId": parentRemoteId.map { .string($0) } ?? .null]
            if withRole, let role { mailbox["role"] = .string(role) }
            var request = JMAPRequest()
            let set = request.call("Mailbox/set", ["accountId": .string(accountId), "create": ["new": .object(mailbox)]])
            return try await client.send(request).arguments(set)["notCreated"]?["new"]
        }
        if var error = try await create(withRole: role != nil) {
            if role != nil { error = try await create(withRole: false) ?? .null }  // Some servers won't set roles.
            if error != .null { throw SendError.rejected(Self.setErrorText(error)) }
        }
        _ = try await syncMailboxes(accountId)
    }

    /// Puts a whole message (its raw RFC 5322 bytes) into a mailbox of this account (blob upload, then
    /// Email/import), keeping its keywords and received date: the copy half of a move from another
    /// account. Returns once the server has confirmed it, then syncs it in.
    public func importMessage(_ raw: Data, mailboxRemoteId: String, keywords: [String], receivedAt: Date) async throws {
        let accountId = try remoteAccountId(try await client.currentSession())
        let blobId = try await client.upload(accountId: accountId, data: raw, type: "message/rfc822")
        var request = JMAPRequest()
        let formatter = ISO8601DateFormatter()
        let imported = request.call("Email/import", [
            "accountId": .string(accountId),
            "emails": .object(["m": .object([
                "blobId": .string(blobId),
                "mailboxIds": .object([mailboxRemoteId: .bool(true)]),
                "keywords": .object(Dictionary(uniqueKeysWithValues: keywords.map { ($0, JSONValue.bool(true)) })),
                "receivedAt": .string(formatter.string(from: receivedAt)),
            ])]),
        ])
        let result = try await client.send(request).arguments(imported)
        guard result["created"]?["m"]?["id"]?.stringValue != nil else {
            throw SendError.rejected(Self.setErrorText(result["notCreated"]?["m"] ?? .null))
        }
        _ = try await sync()
    }

    /// Deletes emails for good (Email/set destroy), here and on the server.
    public func destroy(remoteIds: [String]) async throws {
        guard !remoteIds.isEmpty else { return }
        let accountId = try remoteAccountId(try await client.currentSession())
        var request = JMAPRequest()
        let set = request.call("Email/set", ["accountId": .string(accountId), "destroy": .strings(remoteIds)])
        let failed = Set(try await client.send(request).arguments(set)["notDestroyed"]?.objectValue?.keys ?? [:].keys)
        try store.deleteMessages(accountId: account.id, remoteIds: remoteIds.filter { !failed.contains($0) })
        if !failed.isEmpty {
            throw JMAPError.invalidResponse("the server didn’t delete \(failed.count) message\(failed.count == 1 ? "" : "s")")
        }
    }

    // MARK: Sending

    /// Sends a message (RFC 8621 §7): creates it in Drafts, submits it, and on success the server moves
    /// it to Sent and clears `$draft`. Bcc recipients are only in the envelope, never in the message.
    public func send(_ message: OutgoingMessage) async throws {
        let session = try await client.currentSession()
        guard session.supports(Capability.submission) else { throw JMAPError.missingCapability(Capability.submission) }
        let accountId = try remoteAccountId(session)
        guard let drafts = try store.mailbox(accountId: account.id, role: "drafts") else {
            throw SendError.noMailbox(role: "drafts")
        }
        let sent = try store.mailbox(accountId: account.id, role: "sent")

        var email: [String: JSONValue] = [
            "mailboxIds": .object([drafts.remoteId: true]),
            "keywords": ["$draft": true, "$seen": true],
            "from": Self.json([message.from]),
            "subject": .string(message.subject),
            // As MailMate does: Outlook users can't send reactions, which arrive as stray emails elsewhere.
            "header:X-MS-Reactions:asText": "disallow",
            "sentAt": .string(ISO8601DateFormatter().string(from: Date())),
            "bodyValues": ["text": ["value": .string(message.text)]],
            "textBody": [["partId": "text", "type": "text/plain"]],
        ]
        if !message.to.isEmpty { email["to"] = Self.json(message.to) }
        if !message.cc.isEmpty { email["cc"] = Self.json(message.cc) }
        if !message.replyTo.isEmpty { email["replyTo"] = Self.json(message.replyTo) }
        var parts = message.attachments
        for file in message.files {
            let blobId = try await client.upload(accountId: accountId, data: file.data, type: file.type)
            parts.append(MessagePart(blobId: blobId, cid: nil, type: file.type, name: file.name, size: file.data.count))
        }
        if !parts.isEmpty {
            email["attachments"] = .array(parts.map { part in
                var item: [String: JSONValue] = [
                    "blobId": .string(part.blobId), "type": .string(part.type), "disposition": "attachment",
                ]
                if let name = part.name { item["name"] = .string(name) }
                return .object(item)
            })
        }
        if !message.inReplyTo.isEmpty { email["inReplyTo"] = .strings(message.inReplyTo) }
        if !message.references.isEmpty { email["references"] = .strings(message.references) }

        var afterSend: [String: JSONValue] = ["keywords/$draft": .null]
        if let sent {
            afterSend["mailboxIds/\(drafts.remoteId)"] = .null
            afterSend["mailboxIds/\(sent.remoteId)"] = true
        }
        var request = JMAPRequest(using: [Capability.core, Capability.mail, Capability.submission])
        let create = request.call("Email/set", ["accountId": .string(accountId), "create": ["draft": .object(email)]])
        let submit = request.call("EmailSubmission/set", [
            "accountId": .string(accountId),
            "create": [
                "send": [
                    "identityId": .string(message.identityId),
                    "emailId": "#draft",
                    "envelope": [
                        "mailFrom": ["email": .string(message.mailFrom ?? message.from.email ?? "")],
                        "rcptTo": .array(message.recipients.map { ["email": .string($0)] }),
                    ],
                ]
            ],
            "onSuccessUpdateEmail": ["#send": .object(afterSend)],
        ])
        let response = try await client.send(request)
        let created = try response.arguments(create)
        if let error = created["notCreated"]?["draft"] {
            throw SendError.rejected(Self.setErrorText(error))
        }
        let draftId = created["created"]?["draft"]?["id"]?.stringValue
        let submitted: JSONValue
        do {
            submitted = try response.arguments(submit)
        } catch {
            try? await discardDraft(draftId, accountId)
            throw error
        }
        if let error = submitted["notCreated"]?["send"] {
            try? await discardDraft(draftId, accountId)
            throw SendError.rejected(Self.setErrorText(error))
        }
    }

    /// Redirects a message as it is (a rule's Redirect): submits the stored email to new recipients,
    /// only the envelope changing, so it arrives from its original sender.
    public func redirect(remoteId: String, to recipients: [String], identityId: String, mailFrom: String) async throws {
        let session = try await client.currentSession()
        guard session.supports(Capability.submission) else { throw JMAPError.missingCapability(Capability.submission) }
        let accountId = try remoteAccountId(session)
        var request = JMAPRequest(using: [Capability.core, Capability.mail, Capability.submission])
        let submit = request.call("EmailSubmission/set", [
            "accountId": .string(accountId),
            "create": [
                "redirect": [
                    "identityId": .string(identityId),
                    "emailId": .string(remoteId),
                    "envelope": [
                        "mailFrom": ["email": .string(mailFrom)],
                        "rcptTo": .array(recipients.map { ["email": .string($0)] }),
                    ],
                ]
            ],
        ])
        let result = try await client.send(request).arguments(submit)
        if let error = result["notCreated"]?["redirect"] { throw SendError.rejected(Self.setErrorText(error)) }
    }

    /// In-Reply-To and References for a reply to this message (see `Compose.references`).
    public func replyHeaders(remoteId: String) async throws -> (inReplyTo: [String], references: [String]) {
        let accountId = try remoteAccountId(try await client.currentSession())
        var request = JMAPRequest()
        let get = request.call("Email/get", [
            "accountId": .string(accountId), "ids": .strings([remoteId]),
            "properties": ["messageId", "references", "inReplyTo"],
        ])
        func strings(_ value: JSONValue?) -> [String]? { value?.arrayValue?.compactMap(\.stringValue) }
        guard let original = try await client.send(request).arguments(get)["list"]?.arrayValue?.first,
            let messageId = strings(original["messageId"]), !messageId.isEmpty
        else { return ([], []) }
        return (messageId, Compose.references(
            messageId: messageId, references: strings(original["references"]), inReplyTo: strings(original["inReplyTo"])))
    }

    /// Removes a draft whose submission failed, so a retry doesn't leave copies in Drafts.
    private func discardDraft(_ id: String?, _ accountId: String) async throws {
        guard let id else { return }
        var request = JMAPRequest()
        request.call("Email/set", ["accountId": .string(accountId), "destroy": .strings([id])])
        _ = try await client.send(request)
    }

    private static func json(_ addresses: [EmailAddress]) -> JSONValue {
        .array(addresses.map { a in
            var item: [String: JSONValue] = ["email": .string(a.email ?? "")]
            if let name = a.name, !name.isEmpty, name.lowercased() != a.email?.lowercased() { item["name"] = .string(name) }
            return .object(item)
        })
    }

    /// A SetError's description, else its type ("forbiddenFrom", "tooManyRecipients", ...).
    private static func setErrorText(_ error: JSONValue) -> String {
        let type = error["type"]?.stringValue ?? "unknown"
        return error["description"]?.stringValue.map { "\(type): \($0)" } ?? type
    }

    public enum SendError: Error, LocalizedError {
        case noMailbox(role: String)
        case rejected(String)

        public var errorDescription: String? {
            switch self {
            case .noMailbox(let role): "This account has no \(role == "drafts" ? "Drafts" : role) mailbox."
            case .rejected(let why): "The server didn’t send the message (\(why))."
            }
        }
    }

    /// Puts emails removed from the store back from the server (a move that failed after the UI moved on).
    public func restore(remoteIds: [String]) async throws {
        let accountId = try remoteAccountId(try await client.currentSession())
        try await refetch(remoteIds, accountId)
    }

    /// Stores the server's current copy of these emails (and forgets ones it no longer has).
    private func refetch(_ remoteIds: [String], _ accountId: String) async throws {
        var request = JMAPRequest()
        let get = request.call("Email/get", [
            "accountId": .string(accountId), "ids": .strings(remoteIds), "properties": .strings(Email.properties),
        ])
        let result = try await client.send(request).decode(GetResponse<Email>.self, get)
        try store.upsertMessages(accountId: account.id, result.list.map(Self.incoming))
        try store.deleteMessages(accountId: account.id, remoteIds: result.notFound ?? [])
    }

    // MARK: Mapping

    private func remoteAccountId(_ session: Session) throws -> String {
        if let id = account.remoteAccountId { return id }
        guard let id = session.primaryMailAccountId else { throw JMAPError.missingCapability(Capability.mail) }
        return id
    }

    static func incoming(_ m: Mailbox) -> IncomingMailbox {
        IncomingMailbox(
            remoteId: m.id, parentRemoteId: m.parentId, name: m.name, role: m.role?.lowercased(),
            sortOrder: m.sortOrder ?? 0, totalEmails: m.totalEmails ?? 0, unreadEmails: m.unreadEmails ?? 0)
    }

    /// Empty groups' names, which MailMate shows as recipients ("undisclosed-recipients"); members of
    /// other groups are already in `to` and `cc`.
    static func groupNames(_ groups: [EmailAddressGroup]?, _ role: AddressRole) -> [IncomingMessage.Address] {
        (groups ?? []).compactMap { g in
            guard let name = g.name, !name.isEmpty, g.addresses.isEmpty else { return nil }
            return .init(role: role, name: name, email: "")
        }
    }

    static func incoming(_ e: Email) -> IncomingMessage {
        var addresses: [IncomingMessage.Address] = []
        func add(_ role: AddressRole, _ list: [EmailAddress]?) {
            for a in list ?? [] {
                guard let email = a.email, !email.isEmpty else { continue }
                addresses.append(.init(role: role, name: a.name, email: email))
            }
        }
        add(.from, e.from)
        add(.sender, e.sender)
        add(.to, e.to)
        add(.cc, e.cc)
        add(.bcc, e.bcc)
        add(.replyTo, e.replyTo)
        addresses += groupNames(e.toGroups, .toGroup) + groupNames(e.ccGroups, .ccGroup)

        return IncomingMessage(
            remoteId: e.id, threadId: e.threadId, blobId: e.blobId,
            mailboxRemoteIds: e.mailboxIds.filter(\.value).map(\.key),
            keywords: e.keywords.filter(\.value).map(\.key),
            size: e.size, receivedAt: e.receivedAt, sentAt: e.sentAt,
            messageIdHeader: e.messageId?.first, inReplyTo: e.inReplyTo?.first,
            subject: e.subject ?? "", preview: e.preview ?? "", hasAttachment: e.hasAttachment,
            addresses: addresses, references: e.references ?? [])
    }

    /// Parts worth keeping a reference to: body parts with a Content-ID (embedded images) and everything
    /// JMAP lists as an attachment, named or not (a calendar invite is often an unnamed text/calendar
    /// part beside the text and HTML; MailMate shows it as "Attachment.ics").
    static func parts(_ email: EmailBody) -> [MessagePart] {
        var seen = Set<String>()
        // From the body, only embedded media: some senders (LinkedIn) give the HTML body itself a
        // Content-ID, and it isn't an attachment.
        let embedded = email.htmlBody.filter { $0.cid != nil && !$0.type.lowercased().hasPrefix("text/") }
        return (embedded + email.attachments).compactMap { part in
            guard let blobId = part.blobId, seen.insert(blobId).inserted else { return nil }
            return MessagePart(blobId: blobId, cid: part.cid, type: part.type, name: part.name, size: part.size)
        }
    }

    /// Builds displayable HTML and plain text from the JMAP body structure.
    static func render(_ email: EmailBody) -> MessageBody {
        func value(_ part: EmailBodyPart) -> String? { part.partId.flatMap { email.bodyValues[$0]?.value } }

        // Plain text for display and search; HTML-only parts are reduced to their text.
        let text = email.textBody.compactMap { part in
            value(part).map { part.type.lowercased() == "text/html" ? plainText(fromHTML: $0) : $0 }
        }.joined(separator: "\n\n")
        let hasHTML = email.htmlBody.contains { $0.type.lowercased() == "text/html" }
        guard hasHTML else { return MessageBody(html: nil, text: text) }

        var html = ""
        for part in email.htmlBody {
            guard let v = value(part) else { continue }
            if part.type.lowercased() == "text/html" {
                html += v
            } else if part.type.lowercased().hasPrefix("text/") {
                html += "<pre style=\"white-space: pre-wrap\">" + escapeHTML(v) + "</pre>"
            }
        }
        return MessageBody(html: html, text: text)
    }

    /// Readable text from HTML, for the search index: drops style/script/head and tags,
    /// decodes common entities and collapses whitespace.
    static func plainText(fromHTML html: String) -> String {
        var s = html.replacingOccurrences(
            of: #"(?is)<(style|script|head|title)\b.*?</\1>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<(br|/p|/div|/tr|/li|/h\d)\b[^>]*>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        s = s.replacingOccurrences(of: #"[ \t\r\f]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
