import CryptoKit
import Foundation
import Testing
@testable import SonovoCore

@Suite("Vendored corpus integrity")
struct CorpusIntegrityTests {
    private var fixtures: URL {
        get throws {
            try #require(
                Bundle.module.url(forResource: "Fixtures", withExtension: nil),
                "Fixtures directory missing from the test bundle"
            )
        }
    }

    @Test("Every vendored file matches SHA256SUMS")
    func checksumsMatch() throws {
        let root = try fixtures
        let manifestURL = root.appendingPathComponent("SHA256SUMS")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        var checked = 0
        for line in manifest.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            try #require(parts.count == 2, "Malformed manifest line: \(line)")
            let expected = String(parts[0])
            let relative = String(parts[1])
            let fileURL = root.appendingPathComponent(relative)
            let data = try Data(contentsOf: fileURL)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(actual == expected, "Checksum mismatch for \(relative)")
            checked += 1
        }

        #expect(checked == 140, "Unexpected corpus file count: \(checked)")
    }

    @Test("CommonMark corpus carries all 652 examples")
    func commonMarkCorpusCount() throws {
        let url = try fixtures.appendingPathComponent("cm/spec.json")
        let data = try Data(contentsOf: url)
        let examples = try #require(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        #expect(examples.count == 652)
        #expect(examples.first?["markdown"] as? String == "\tfoo\tbaz\t\tbim\n")
    }

    @Test("GFM and extension corpora are present and non-empty")
    func gfmCorporaPresent() throws {
        let root = try fixtures
        for relative in [
            "gfm/spec.txt",
            "gfmreg/regression.txt",
            "gfmext/extensions.txt",
            "xss/xss.txt",
            "math/math.txt"
        ] {
            let data = try Data(contentsOf: root.appendingPathComponent(relative))
            #expect(!data.isEmpty, "\(relative) is empty")
        }
    }
}
