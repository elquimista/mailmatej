import CryptoKit
import Foundation

/// Finding a newer MailMateJ among the GitHub releases the release workflow publishes to a public
/// repository (one per tag, with MailMateJ-<version>.zip; a tag with a hyphen is a prerelease), and
/// downloading it.
public enum SoftwareUpdate {
    /// A version as tags have it ("v1.19.0", "1.19.0-beta2"): numbers, then an optional prerelease
    /// label that comes before the version itself (1.19.0-beta2 < 1.19.0).
    public struct Version: Comparable, CustomStringConvertible, Sendable {
        public let numbers: [Int]
        public let prerelease: String?

        public init?(_ text: String) {
            var text = Substring(text.trimmingCharacters(in: .whitespaces))
            if text.first == "v" || text.first == "V" { text = text.dropFirst() }
            let parts = text.split(separator: "-", maxSplits: 1)
            guard let first = parts.first else { return nil }
            let numbers = first.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
            self.numbers = numbers.compactMap { $0 }
            prerelease = parts.count > 1 ? String(parts[1]) : nil
        }

        public var description: String { numbers.map(String.init).joined(separator: ".") + (prerelease.map { "-" + $0 } ?? "") }

        public static func < (a: Version, b: Version) -> Bool {
            let count = max(a.numbers.count, b.numbers.count)
            for i in 0..<count {
                let x = i < a.numbers.count ? a.numbers[i] : 0
                let y = i < b.numbers.count ? b.numbers[i] : 0
                if x != y { return x < y }
            }
            switch (a.prerelease, b.prerelease) {
            case (nil, nil), (nil, _): return false
            case (_, nil): return true
            case let (x?, y?): return x.compare(y, options: .numeric) == .orderedAscending
            }
        }

        public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
    }

    /// A GitHub release (the fields used).
    public struct Release: Decodable, Sendable {
        public let tagName: String
        public let name: String?
        public let draft: Bool
        public let prerelease: Bool
        public let htmlURL: URL
        public let assets: [Asset]

        public struct Asset: Decodable, Sendable {
            public let id: Int
            public let name: String
            public let size: Int
            /// "sha256:<hex>", where GitHub gives it.
            public let digest: String?
            /// The API's URL for it (downloads with Accept: application/octet-stream).
            public let url: URL
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", name, draft, prerelease, htmlURL = "html_url", assets
        }

        public var version: Version? { Version(tagName) }

        /// The app's zip, as the release workflow names it.
        public var app: Asset? {
            version.flatMap { v in assets.first { $0.name == "MailMateJ-\(v).zip" } } ?? assets.first { $0.name.hasSuffix(".zip") }
        }
    }

    /// The newest release newer than `current` (with its app): prereleases too with `betas`, never drafts.
    public static func newest(in releases: [Release], newerThan current: Version, betas: Bool) -> Release? {
        releases
            .filter { !$0.draft && (betas || !$0.prerelease) && $0.app != nil }
            .compactMap { release in release.version.map { (release, $0) } }
            .filter { current < $0.1 }
            .max { $0.1 < $1.1 }?.0
    }

    /// Why a check or download didn't work, in words for an alert.
    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// GitHub's API for one repository ("owner/name"); a token only for a private one.
    public struct GitHub: Sendable {
        public let repository: String
        public let token: String?
        public let api: URL

        public init(repository: String, token: String? = nil, api: URL = URL(string: "https://api.github.com")!) {
            self.repository = repository
            self.token = token
            self.api = api
        }

        /// The repository's latest releases, newest first.
        public func releases(session: URLSession = .shared) async throws -> [Release] {
            var request = URLRequest(url: api.appendingPathComponent("repos/\(repository)/releases"))
            request.url = URL(string: request.url!.absoluteString + "?per_page=30")
            authorize(&request, accept: "application/vnd.github+json")
            let (data, response) = try await session.data(for: request)
            try check(response)
            return try JSONDecoder().decode([Release].self, from: data)
        }

        /// Downloads an asset to a file of its own, reporting the bytes so far; checks its size and digest.
        public func download(
            _ asset: Release.Asset, to file: URL, progress: @escaping @Sendable (Int64) -> Void
        ) async throws {
            var request = URLRequest(url: asset.url)
            authorize(&request, accept: "application/octet-stream")
            let delegate = RedirectWithoutToken()
            let (bytes, response) = try await URLSession.shared.bytes(for: request, delegate: delegate)
            try check(response)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            var buffer = Data()
            buffer.reserveCapacity(1 << 16)
            var written: Int64 = 0
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count == 1 << 16 {
                    try handle.write(contentsOf: buffer)
                    hasher.update(data: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    progress(written)
                }
            }
            try handle.write(contentsOf: buffer)
            hasher.update(data: buffer)
            written += Int64(buffer.count)
            progress(written)
            guard written == asset.size else {
                throw Failure(message: "The download is incomplete (\(written) of \(asset.size) bytes).")
            }
            if let digest = asset.digest, digest.hasPrefix("sha256:") {
                let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard hex == digest.dropFirst(7).lowercased() else {
                    throw Failure(message: "The download doesn’t match the release’s checksum.")
                }
            }
        }

        private func authorize(_ request: inout URLRequest, accept: String) {
            request.setValue(accept, forHTTPHeaderField: "Accept")
            if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 30
        }

        private func check(_ response: URLResponse) throws {
            guard let http = response as? HTTPURLResponse else { throw Failure(message: "GitHub didn’t answer.") }
            switch http.statusCode {
            case 200..<300: return
            case 403, 429: throw Failure(message: "GitHub limits how often it’s asked (\(http.statusCode)). Try again later.")
            case 404: throw Failure(message: "GitHub has no repository \(repository) for releases.")
            default: throw Failure(message: "GitHub answered \(http.statusCode).")
            }
        }
    }

    /// A download goes on to storage elsewhere (a signed address), which mustn't get the token.
    private final class RedirectWithoutToken: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            var request = request
            if request.url?.host != task.originalRequest?.url?.host {
                request.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            return request
        }
    }

    /// "owner/name" from a git remote's URL (https://github.com/owner/name.git, git@host:owner/name.git).
    public static func repository(fromRemote remote: String) -> String? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".git") { text.removeLast(4) }
        let parts = text.split(whereSeparator: { $0 == "/" || $0 == ":" })
        guard parts.count >= 2 else { return nil }
        return parts.suffix(2).joined(separator: "/")
    }
}
