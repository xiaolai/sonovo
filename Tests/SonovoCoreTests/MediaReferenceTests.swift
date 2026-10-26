import Foundation
import Testing
@testable import SonovoCore

@Suite("Media references")
struct MediaReferenceTests {
    @Test("Parses a take with a path, seconds, and label")
    func take() throws {
        let reference = try #require(
            MediaReference.parse(
                "sonovo:take?path=edit/take-2.mov&seconds=12.5"
                    + "&label=Take%202"
            )
        )
        #expect(reference.kind == .take)
        #expect(reference.path == "edit/take-2.mov")
        #expect(reference.seconds == 12.5)
        #expect(reference.label == "Take 2")
    }

    @Test("Parses a timecode and converts H:MM:SS.fff")
    func timecode() throws {
        let reference = try #require(
            MediaReference.parse(
                "sonovo:timecode?path=edit/master.mov&t=00:12:34.5"
            )
        )
        #expect(reference.kind == .timecode)
        #expect(reference.seconds == 754.5)
        #expect(reference.path == "edit/master.mov")
    }

    @Test("Accepts M:SS and the URL-authority spelling")
    func alternateSpellings() throws {
        let short = try #require(
            MediaReference.parse("sonovo:timecode?t=2:05")
        )
        #expect(short.seconds == 125)
        let authority = try #require(
            MediaReference.parse("sonovo://take?path=a.mov")
        )
        #expect(authority.path == "a.mov")
        #expect(authority.seconds == nil)
    }

    @Test("A timecode link needs a time; a take link does not")
    func requiredTime() {
        #expect(MediaReference.parse("sonovo:timecode?path=a.mov") == nil)
        #expect(MediaReference.parse("sonovo:take?path=a.mov") != nil)
        #expect(MediaReference.parse("sonovo:take") != nil)
    }

    @Test("Refuses traversal, absolute paths, and other schemes")
    func unsafePaths() {
        #expect(
            MediaReference.parse("sonovo:take?path=../secret.mov") == nil
        )
        #expect(
            MediaReference.parse("sonovo:take?path=/etc/passwd") == nil
        )
        #expect(
            MediaReference.parse("sonovo:take?path=a%2F..%2Fb.mov") == nil
        )
        #expect(
            MediaReference.parse("sonovo:take?path=a\\b.mov") == nil
        )
        #expect(
            MediaReference.parse("sonovo:take?path=https://x/y.mov") == nil
        )
        #expect(MarkdownSecurity.isValidRelativePath("") == false)
        #expect(MarkdownSecurity.isValidRelativePath("a/../b") == false)
        #expect(MarkdownSecurity.isValidRelativePath("a/take 2.mov"))
    }

    @Test("Refuses unknown and duplicate query keys")
    func queryValidation() {
        #expect(
            MediaReference.parse("sonovo:take?path=a.mov&speed=2") == nil
        )
        #expect(
            MediaReference.parse("sonovo:take?path=a.mov&path=b.mov") == nil
        )
        #expect(
            MediaReference.parse(
                "sonovo:timecode?seconds=1&t=00:00:02"
            ) == nil
        )
        #expect(
            MediaReference.parse("sonovo:take?label=a&label=b") == nil
        )
        #expect(
            MediaReference.parse("sonovo:take?broken=%ZZ") == nil
        )
    }

    @Test("Refuses invalid times")
    func timeValidation() {
        #expect(
            MediaReference.parse("sonovo:timecode?seconds=-1") == nil
        )
        #expect(
            MediaReference.parse("sonovo:timecode?seconds=nan") == nil
        )
        #expect(
            MediaReference.parse("sonovo:timecode?t=00:60:00") == nil
        )
        #expect(
            MediaReference.parse("sonovo:timecode?t=00:00:60") == nil
        )
        #expect(
            MediaReference.parse("sonovo:timecode?t=1:2:3:4") == nil
        )
        #expect(MediaReference.timecodeSeconds("10:00") == 600)
        #expect(MediaReference.timecodeSeconds("1:02:03.5") == 3723.5)
    }

    @Test("The canonical URL round-trips")
    func urlRoundTrip() throws {
        let reference = try #require(
            MediaReference.parse(
                "sonovo:take?path=a b.mov&seconds=1.5&label=Take 2"
            )
        )
        let url = try #require(reference.url())
        #expect(MediaReference.parse(url.absoluteString) == reference)
    }

    @Test("The security policy admits only valid media links")
    func securityDecision() {
        #expect(
            MarkdownSecurity.linkDecision(
                for: "sonovo:take?path=a.mov"
            ) == .allowed(.media)
        )
        #expect(
            MarkdownSecurity.linkDecision(
                for: "sonovo:take?path=../a.mov"
            ) == .denied("invalid media link")
        )
        #expect(
            MarkdownLinkActivation.decide("sonovo:take?path=a.mov")
                == .openDirectly(.media)
        )
    }
}
