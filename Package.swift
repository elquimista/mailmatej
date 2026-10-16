// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MailMateJ",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MailMateJ", targets: ["MailMateJ"]),
        .executable(name: "mmj-sync", targets: ["mmj-sync"]),
        .library(name: "JMAPKit", targets: ["JMAPKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Protocol layer: JMAP core + mail. No UI, no storage.
        .target(name: "JMAPKit"),
        // Local source of truth: SQLite schema, queries, raw .eml store.
        .target(
            name: "MailStore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        // Sync engines (JMAP now, IMAP later) writing into MailStore.
        .target(name: "MailSync", dependencies: ["JMAPKit", "MailStore"]),
        // The AppKit app.
        .executableTarget(name: "MailMateJ", dependencies: ["MailSync", "MailStore", "JMAPKit"]),
        // Headless sync tool for development and testing.
        .executableTarget(name: "mmj-sync", dependencies: ["MailSync", "MailStore", "JMAPKit"]),
        .testTarget(name: "JMAPKitTests", dependencies: ["JMAPKit"]),
        .testTarget(name: "MailStoreTests", dependencies: ["MailStore"]),
        .testTarget(name: "MailSyncTests", dependencies: ["MailSync", "JMAPKit", "MailStore"]),
    ]
)
