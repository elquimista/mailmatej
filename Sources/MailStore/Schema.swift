import GRDB

enum Schema {
    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE account (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    kind TEXT NOT NULL,              -- 'jmap' (later 'imap')
                    sessionURL TEXT NOT NULL,
                    username TEXT NOT NULL,
                    authKind TEXT NOT NULL,          -- 'basic' | 'bearer'
                    remoteAccountId TEXT,
                    sortOrder INTEGER NOT NULL DEFAULT 0,
                    isEnabled INTEGER NOT NULL DEFAULT 1
                );

                -- Opaque per-type sync cursors (JMAP state strings; IMAP will store UIDVALIDITY/MODSEQ here).
                CREATE TABLE syncState (
                    accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                    objectType TEXT NOT NULL,
                    state TEXT NOT NULL,
                    PRIMARY KEY (accountId, objectType)
                );

                CREATE TABLE identity (
                    accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                    remoteId TEXT NOT NULL,
                    name TEXT NOT NULL,
                    email TEXT NOT NULL,             -- lowercased
                    PRIMARY KEY (accountId, remoteId)
                );

                CREATE TABLE mailbox (
                    id INTEGER PRIMARY KEY,
                    accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                    remoteId TEXT NOT NULL,
                    parentRemoteId TEXT,
                    name TEXT NOT NULL,
                    role TEXT,
                    sortOrder INTEGER NOT NULL DEFAULT 0,
                    totalEmails INTEGER NOT NULL DEFAULT 0,
                    unreadEmails INTEGER NOT NULL DEFAULT 0,
                    UNIQUE (accountId, remoteId)
                );
                CREATE INDEX mailbox_role ON mailbox(role);

                CREATE TABLE message (
                    id INTEGER PRIMARY KEY,
                    accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                    remoteId TEXT NOT NULL,
                    threadId TEXT NOT NULL,
                    blobId TEXT NOT NULL,
                    messageIdHeader TEXT,
                    inReplyTo TEXT,
                    subject TEXT NOT NULL,
                    sortSubject TEXT NOT NULL,       -- lowercased, without Re:/Fwd: prefixes
                    fromDisplay TEXT NOT NULL,       -- name, or address when there is no name
                    fromEmail TEXT NOT NULL,         -- lowercased
                    preview TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    receivedAt REAL NOT NULL,
                    sentAt REAL,
                    hasAttachment INTEGER NOT NULL,
                    isSeen INTEGER NOT NULL,
                    isFlagged INTEGER NOT NULL,
                    isAnswered INTEGER NOT NULL,
                    isDraft INTEGER NOT NULL,
                    UNIQUE (accountId, remoteId)
                );
                CREATE INDEX message_received ON message(receivedAt);
                CREATE INDEX message_thread ON message(accountId, threadId);
                CREATE INDEX message_flagged ON message(receivedAt) WHERE isFlagged;
                CREATE INDEX message_unread ON message(receivedAt) WHERE NOT isSeen;

                -- Many-to-many: JMAP allows a message in several mailboxes. IMAP is the 1:1 case.
                CREATE TABLE message_mailbox (
                    messageId INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                    mailboxId INTEGER NOT NULL REFERENCES mailbox(id) ON DELETE CASCADE,
                    PRIMARY KEY (messageId, mailboxId)
                ) WITHOUT ROWID;
                CREATE INDEX message_mailbox_mailbox ON message_mailbox(mailboxId, messageId);

                CREATE TABLE message_keyword (
                    messageId INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                    keyword TEXT NOT NULL,
                    PRIMARY KEY (messageId, keyword)
                ) WITHOUT ROWID;
                CREATE INDEX message_keyword_keyword ON message_keyword(keyword, messageId);

                -- One row per address per header. Drives correspondence, smart mailboxes and search.
                CREATE TABLE address (
                    messageId INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                    role INTEGER NOT NULL,           -- AddressRole
                    position INTEGER NOT NULL,
                    name TEXT,
                    email TEXT NOT NULL,             -- lowercased
                    PRIMARY KEY (messageId, role, position)
                ) WITHOUT ROWID;
                CREATE INDEX address_email ON address(email, messageId);

                CREATE TABLE message_body (
                    messageId INTEGER PRIMARY KEY REFERENCES message(id) ON DELETE CASCADE,
                    html TEXT,
                    text TEXT,
                    fetchedAt REAL NOT NULL
                );

                CREATE VIRTUAL TABLE message_fts USING fts5(
                    subject, addresses, body,
                    tokenize = 'unicode61 remove_diacritics 2'
                );
                CREATE TRIGGER message_fts_delete AFTER DELETE ON message BEGIN
                    DELETE FROM message_fts WHERE rowid = old.id;
                END;

                -- Smart mailboxes: a condition tree (JSON) with incrementally maintained membership.
                CREATE TABLE smart_mailbox (
                    id INTEGER PRIMARY KEY,
                    parentId INTEGER REFERENCES smart_mailbox(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    definition TEXT NOT NULL,
                    sortOrder INTEGER NOT NULL DEFAULT 0,
                    version INTEGER NOT NULL DEFAULT 1
                );
                CREATE TABLE smart_membership (
                    smartId INTEGER NOT NULL REFERENCES smart_mailbox(id) ON DELETE CASCADE,
                    messageId INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                    PRIMARY KEY (smartId, messageId)
                ) WITHOUT ROWID;
                CREATE INDEX smart_membership_message ON smart_membership(messageId);

                -- Outbox for local-first mutations (flag, move, delete, rule actions), replayed to the server.
                CREATE TABLE pending_change (
                    id INTEGER PRIMARY KEY,
                    accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    createdAt REAL NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    lastError TEXT
                );
                """)
        }

        m.registerMigration("v2-parts-and-remote-content") { db in
            try db.execute(sql: """
                -- Body parts of fetched messages, so embedded (cid:) images can be served.
                CREATE TABLE message_part (
                    messageId INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                    blobId TEXT NOT NULL,
                    cid TEXT,                        -- lowercased, without <>
                    type TEXT NOT NULL,
                    name TEXT,
                    size INTEGER,
                    PRIMARY KEY (messageId, blobId)
                ) WITHOUT ROWID;
                CREATE INDEX message_part_cid ON message_part(messageId, cid);

                -- Senders ("a@b.com") and domains ("@b.com") whose remote content loads automatically.
                CREATE TABLE remote_content_allow (
                    value TEXT PRIMARY KEY,
                    addedAt REAL NOT NULL
                );

                -- Cached bodies predate part tracking; refetch them on demand.
                DELETE FROM message_body;
                """)
        }

        m.registerMigration("v3-full-download") { db in
            try db.execute(sql: """
                -- Whether the full message (raw .eml plus body text and parts) is stored locally:
                -- 0 = not yet, 1 = downloaded, 2 = failed this run (retried on the next launch).
                ALTER TABLE message ADD COLUMN downloadState INTEGER NOT NULL DEFAULT 0;
                CREATE INDEX message_download_pending ON message(accountId, receivedAt) WHERE downloadState = 0;
                """)
        }

        m.registerMigration("v4-part-position") { db in
            // The part's place in the message, so attachments list in the sender's order.
            try db.execute(sql: "ALTER TABLE message_part ADD COLUMN position INTEGER NOT NULL DEFAULT 0")
        }

        m.registerMigration("v5-unnamed-attachments") { db in
            // Unnamed attachments (e.g. calendar invites) weren't kept before. Refetch the bodies and part
            // lists of messages with attachments; the downloader skips .eml files already on disk.
            try db.execute(sql: """
                DELETE FROM message_body WHERE messageId IN (SELECT id FROM message WHERE hasAttachment);
                DELETE FROM message_part WHERE messageId IN (SELECT id FROM message WHERE hasAttachment);
                UPDATE message SET downloadState = 0 WHERE hasAttachment;
                """)
        }

        m.registerMigration("v6-body-parts-not-attachments") { db in
            // HTML or text bodies that carried a Content-ID were kept as parts and listed as attachments.
            try db.execute(sql: """
                DELETE FROM message_part
                WHERE cid IS NOT NULL AND name IS NULL AND type IN ('text/html', 'text/plain')
                """)
        }

        m.registerMigration("v7-account-identity") { db in
            // Full Name and Email Address(es) from the account settings window.
            try db.execute(sql: """
                ALTER TABLE account ADD COLUMN fullName TEXT NOT NULL DEFAULT '';
                ALTER TABLE account ADD COLUMN emailAddresses TEXT NOT NULL DEFAULT '';
                """)
        }

        m.registerMigration("v8-infer-archive") { db in
            // A top-level "Archive" stands in for an account without an archive-role mailbox
            // (MailStore.inferArchive does the same on every mailbox sync).
            for accountId in try String.fetchAll(db, sql: "SELECT id FROM account") {
                try MailStore.inferArchive(db, accountId: accountId, serverArchive: nil)
            }
        }

        m.registerMigration("v9-references") { db in
            // The References header (Message-IDs, space-separated), for threading by reply headers.
            // NULL until fetched: messages stored before this are filled in by the next sync.
            try db.execute(sql: "ALTER TABLE message ADD COLUMN referencesHeader TEXT")
        }

        return m
    }
}
