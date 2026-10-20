import Foundation
import Testing
@testable import SonovoCore

private func apply(
    _ edit: SubtitleEdit,
    to source: String,
    format: SubtitleFormat
) throws -> SubtitleEditResult {
    let parse = SubtitleParser.parse(source, format: format)
    return try SubtitleEditor.apply(edit, to: parse, source: source)
}

private let srt = """
1
00:00:01,000 --> 00:00:03,000
Hello

2
00:00:04,000 --> 00:00:06,000
World
"""

private let vtt = """
WEBVTT

00:00:01.000 --> 00:00:02.000
Hello
"""

private let ass = """
[Script Info]
Title: Demo

[V4+ Styles]
Format: Name, Fontname, Fontsize
Style: Default,Arial,20

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:03.00,Default,Alice,0000,0000,0000,,Hello, {\\i1}world{\\i0}!
"""

@Suite("Subtitle text edits")
struct SubtitleTextEditingTests {
    @Test("Replacing cue text touches only the text range")
    func setTextMinimal() throws {
        let result = try apply(
            .setText(ordinal: 0, text: "Hello, world!"),
            to: srt,
            format: .srt
        )
        let expected = """
        1
        00:00:01,000 --> 00:00:03,000
        Hello, world!

        2
        00:00:04,000 --> 00:00:06,000
        World
        """
        #expect(result.source == expected)
        #expect(result.actionName == "Edit Cue")
        #expect(result.affectedCueOrdinal == 0)
        let parse = SubtitleParser.parse(result.source, format: .srt)
        #expect(parse.cues.map(\.rawText) == ["Hello, world!", "World"])
        let original = SubtitleParser.parse(srt, format: .srt)
        let secondCueStart = original.cues[1].blockRange.lowerBound
        let originalSuffix = (srt as NSString).substring(from: secondCueStart)
        #expect(result.source.hasSuffix(originalSuffix))
    }

    @Test("Multiline text is preserved; a blank line is collapsed")
    func setTextMultiline() throws {
        let result = try apply(
            .setText(ordinal: 0, text: "Line one\n\nLine two\n"),
            to: srt,
            format: .srt
        )
        let parse = SubtitleParser.parse(result.source, format: .srt)
        #expect(parse.cues[0].rawText == "Line one\nLine two")
        #expect(parse.cues.count == 2)
    }

    @Test("An identical text edit is a no-op")
    func noOp() throws {
        let result = try apply(
            .setText(ordinal: 0, text: "Hello"),
            to: srt,
            format: .srt
        )
        #expect(result.source == srt)
        #expect(result.changedRange.isEmpty)
    }

    @Test("Filling an empty cue adds a text line without a blank line")
    func fillEmptyCue() throws {
        let source = """
        1
        00:00:01,000 --> 00:00:02,000

        2
        00:00:03,000 --> 00:00:04,000
        Two
        """
        let result = try apply(
            .setText(ordinal: 0, text: "Filled"),
            to: source,
            format: .srt
        )
        let parse = SubtitleParser.parse(result.source, format: .srt)
        #expect(parse.cues.count == 2)
        #expect(parse.cues[0].rawText == "Filled")
        #expect(parse.cues[1].rawText == "Two")
    }

    @Test("ASS text edits preserve commas, overrides, and every other field")
    func setTextASS() throws {
        let result = try apply(
            .setText(ordinal: 0, text: "Hi, there"),
            to: ass,
            format: .ass
        )
        #expect(
            result.source.hasSuffix(
                "Dialogue: 0,0:00:01.00,0:00:03.00,Default,Alice,"
                    + "0000,0000,0000,,Hi, there"
            )
        )
        #expect(result.source.hasPrefix("[Script Info]\nTitle: Demo"))
        let parse = SubtitleParser.parse(result.source, format: .ass)
        #expect(parse.cues[0].rawText == "Hi, there")
        #expect(parse.assInfo?.formatFields.count == 10)
    }

    @Test("ASS line breaks become \\N")
    func assLineBreak() throws {
        let result = try apply(
            .setText(ordinal: 0, text: "One\nTwo"),
            to: ass,
            format: .ass
        )
        let parse = SubtitleParser.parse(result.source, format: .ass)
        #expect(parse.cues[0].rawText == "One\\NTwo")
    }

    @Test("An unknown cue ordinal is rejected")
    func unknownCue() {
        #expect(throws: SubtitleEditError.cueNotFound(9)) {
            _ = try apply(
                .setText(ordinal: 9, text: "x"),
                to: srt,
                format: .srt
            )
        }
    }
}

@Suite("Subtitle timing edits")
struct SubtitleTimingEditingTests {
    @Test("Timing replacement rewrites only the two timestamp tokens")
    func setTiming() throws {
        let result = try apply(
            .setTiming(
                ordinal: 1,
                startMilliseconds: 10_000,
                endMilliseconds: 12_500
            ),
            to: srt,
            format: .srt
        )
        let expected = """
        1
        00:00:01,000 --> 00:00:03,000
        Hello

        2
        00:00:10,000 --> 00:00:12,500
        World
        """
        #expect(result.source == expected)
        let parse = SubtitleParser.parse(result.source, format: .srt)
        #expect(parse.cues[1].startMilliseconds == 10_000)
        #expect(parse.cues[1].endMilliseconds == 12_500)
    }

    @Test("ASS timing edits use centiseconds")
    func assTiming() throws {
        let result = try apply(
            .setTiming(
                ordinal: 0,
                startMilliseconds: 6_000,
                endMilliseconds: 7_004
            ),
            to: ass,
            format: .ass
        )
        #expect(
            result.source.contains(
                "Dialogue: 0,0:00:06.00,0:00:07.00,Default,Alice,"
            )
        )
    }

    @Test("Invalid timings are rejected")
    func invalidTiming() {
        #expect(
            throws: SubtitleEditError.invalidTiming(
                startMilliseconds: 5000,
                endMilliseconds: 5000
            )
        ) {
            _ = try apply(
                .setTiming(
                    ordinal: 0,
                    startMilliseconds: 5000,
                    endMilliseconds: 5000
                ),
                to: srt,
                format: .srt
            )
        }
        #expect(
            throws: SubtitleEditError.invalidTiming(
                startMilliseconds: -1,
                endMilliseconds: 1000
            )
        ) {
            _ = try apply(
                .setTiming(
                    ordinal: 0,
                    startMilliseconds: -1,
                    endMilliseconds: 1000
                ),
                to: srt,
                format: .srt
            )
        }
    }
}

