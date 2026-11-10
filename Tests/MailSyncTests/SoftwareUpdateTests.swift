import Foundation
import Testing

@testable import MailSync

@Suite struct SoftwareUpdateTests {
    typealias Version = SoftwareUpdate.Version

    @Test func versionsCompareAsTagsMean() throws {
        #expect(try #require(Version("v1.18.1")) < #require(Version("1.19.0")))
        #expect(try #require(Version("1.9.0")) < #require(Version("1.10.0")))
        #expect(try #require(Version("1.19.0-beta2")) < #require(Version("1.19.0")))
        #expect(try #require(Version("1.19.0-beta2")) < #require(Version("1.19.0-beta10")))
        #expect(try #require(Version("1.18")) == #require(Version("1.18.0")))
        #expect(Version("v1.x") == nil && Version("") == nil)
        #expect(Version("v1.19.0-beta1")?.description == "1.19.0-beta1")
    }

    @Test func newestIsTheChannelsNewestWithAnApp() throws {
        let json = """
            [{"tag_name": "v1.20.0-beta1", "name": "MailMateJ 1.20.0-beta1", "draft": false, "prerelease": true,
              "html_url": "https://github.com/o/r/releases/tag/v1.20.0-beta1",
              "assets": [{"id": 3, "name": "MailMateJ-1.20.0-beta1.zip", "size": 10, "url": "https://api.github.com/a/3"}]},
             {"tag_name": "v1.21.0", "name": null, "draft": true, "prerelease": false,
              "html_url": "https://github.com/o/r/releases/tag/v1.21.0",
              "assets": [{"id": 4, "name": "MailMateJ-1.21.0.zip", "size": 10, "url": "https://api.github.com/a/4"}]},
             {"tag_name": "v1.19.1", "name": null, "draft": false, "prerelease": false,
              "html_url": "https://github.com/o/r/releases/tag/v1.19.1", "assets": []},
             {"tag_name": "v1.19.0", "name": "MailMateJ 1.19.0", "draft": false, "prerelease": false,
              "html_url": "https://github.com/o/r/releases/tag/v1.19.0",
              "assets": [{"id": 2, "name": "MailMateJ-1.19.0.zip", "size": 10, "digest": "sha256:ab", "url": "https://api.github.com/a/2"}]},
             {"tag_name": "v1.18.1", "name": "MailMateJ 1.18.1", "draft": false, "prerelease": false,
              "html_url": "https://github.com/o/r/releases/tag/v1.18.1",
              "assets": [{"id": 1, "name": "MailMateJ-1.18.1.zip", "size": 10, "url": "https://api.github.com/a/1"}]}]
            """
        let releases = try JSONDecoder().decode([SoftwareUpdate.Release].self, from: Data(json.utf8))
        let current = try #require(Version("1.18.1"))
        // A draft never, one without its app never (1.19.1 is still building), a prerelease only for betas.
        #expect(SoftwareUpdate.newest(in: releases, newerThan: current, betas: false)?.tagName == "v1.19.0")
        #expect(SoftwareUpdate.newest(in: releases, newerThan: current, betas: true)?.tagName == "v1.20.0-beta1")
        #expect(SoftwareUpdate.newest(in: releases, newerThan: try #require(Version("1.19.0")), betas: false) == nil)
        #expect(releases[3].app?.digest == "sha256:ab")
    }

    @Test func repositoryComesFromTheRemote() {
        #expect(SoftwareUpdate.repository(fromRemote: "github_elquimista:elquimista/mailmatej.git") == "elquimista/mailmatej")
        #expect(SoftwareUpdate.repository(fromRemote: "https://github.com/elquimista/mailmatej") == "elquimista/mailmatej")
        #expect(SoftwareUpdate.repository(fromRemote: "mailmatej") == nil)
    }
}
