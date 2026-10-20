import Foundation
import Testing
@testable import SonovoCore

private func slice(_ source: String, _ range: Range<Int>) -> String {
    (source as NSString).substring(
        with: NSRange(location: range.lowerBound, length: range.count)
    )
}

private func parseSRT(_ source: String) -> SubtitleParseResult {
    SubtitleParser.parse(source, format: .srt)
}

private func parseVTT(_ source: String) -> SubtitleParseResult {
    SubtitleParser.parse(source, format: .vtt)
}

private func parseASS(
    _ source: String,
    format: SubtitleFormat = .ass
) -> SubtitleParseResult {
    SubtitleParser.parse(source, format: format)
}

private let srtTwoCues = """
1
00:00:01,000 --> 00:00:03,000
Hello

2
00:00:04,000 --> 00:00:06,000
World
"""

private let assSample = """
[Script Info]
Title: Demo

[V4+ Styles]
Format: Name, Fontname, Fontsize
Style: Default,Arial,20

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:03.00,Default,Alice,0000,0000,0000,,Hello, {\\i1}world{\\i0}!
"""

@Suite("Subtitle format detection")
struct SubtitleFormatDetectionTests {
    @Test("Content wins over the file extension")
    func contentSniffing() {
        #expect(
            SubtitleFormat.detect(
                url: URL(fileURLWithPath: "/tmp/x.srt"),
                source: "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi"
            ) == .vtt
        )
        #expect(
            SubtitleFormat.detect(
                url: URL(fileURLWithPath: "/tmp/x.vtt"),
                source: "[Script Info]\n[Events]\n"
            ) == .ass
        )
        #expect(
            SubtitleFormat.detect(
                url: URL(fileURLWithPath: "/tmp/x.ass"),
                source: "[Script Info]\n[V4 Styles]\n[Events]\n"
            ) == .ssa
        )
        #expect(
            SubtitleFormat.detect(
                url: URL(fileURLWithPath: "/tmp/x.txt"),
                source: "1\n00:00:01,000 --> 00:00:02,000\nHi"
            ) == .srt
        )
    }

    @Test("The extension is the fallback")
    func extensionFallback() {
        #expect(
            SubtitleFormat.detect(
                url: URL(fileURLWithPath: "/tmp/x.vtt"),
                source: "no cues yet"
            ) == .vtt
        )
        #expect(
            SubtitleFormat.detect(
                url: URL(fileURLWithPath: "/tmp/x.unknown"),
                source: ""
            ) == nil
        )
        #expect(SubtitleFormat.format(forExtension: "SSA") == .ssa)
    }
}

@Suite("Subtitle timecodes")
struct SubtitleTimecodeTests {
    @Test("Parses every format's timestamp syntax")
    func parse() {
        #expect(
            SubtitleTimecode.parse(
                "00:00:01,250",
                allowsHourless: true,
                decimalSeparator: nil
            ) == 1250
        )
        #expect(
            SubtitleTimecode.parse(
                "01:02.500",
                allowsHourless: true,
                decimalSeparator: nil
            ) == 62_500
        )
        #expect(
            SubtitleTimecode.parse(
                "0:00:01.25",
                allowsHourless: false,
                decimalSeparator: nil
            ) == 1250
        )
    }

    @Test("Rejects malformed and out-of-range timestamps")
    func rejections() {
        #expect(
            SubtitleTimecode.parse(
                "00:99:01,000",
                allowsHourless: true,
                decimalSeparator: nil
            ) == nil
        )
        #expect(
            SubtitleTimecode.parse(
                "00:00:01,1234",
                allowsHourless: true,
                decimalSeparator: nil
            ) == nil
        )
        #expect(
            SubtitleTimecode.parse(
                "1:02.5",
                allowsHourless: false,
                decimalSeparator: nil
            ) == nil
        )
        #expect(
            SubtitleTimecode.parse(
                "00:00:aa",
                allowsHourless: true,
                decimalSeparator: nil
            ) == nil
        )
        #expect(SubtitleTimecode.parseUserInput("") == nil)
        #expect(SubtitleTimecode.parseUserInput("later") == nil)
    }

    @Test("Formats with the document's own syntax")
    func format() {
        #expect(
            SubtitleTimecode.format(milliseconds: 3_723_004, format: .srt)
                == "01:02:03,004"
        )
        #expect(
            SubtitleTimecode.format(milliseconds: 3_723_004, format: .vtt)
                == "01:02:03.004"
        )
        #expect(
            SubtitleTimecode.format(milliseconds: 3_723_004, format: .ass)
                == "1:02:03.00"
        )
        // ASS centiseconds round the whole value, carrying into seconds.
        #expect(
            SubtitleTimecode.format(milliseconds: 1_996, format: .ass)
                == "0:00:02.00"
        )
        #expect(
            SubtitleTimecode.format(milliseconds: -5, format: .srt)
                == "00:00:00,000"
        )
    }

    @Test("User input accepts commas, dots, and plain seconds")
    func userInput() {
        #expect(SubtitleTimecode.parseUserInput("00:00:02,500") == 2500)
        #expect(SubtitleTimecode.parseUserInput("2.5") == 2500)
        #expect(SubtitleTimecode.parseUserInput("  00:01.000 ") == 1000)
    }
}

@Suite("SRT parsing")
struct SRTParsingTests {
    @Test("Projects cues with exact ranges")
    func ranges() {
        let result = parseSRT(srtTwoCues)
        #expect(result.cues.count == 2)
        #expect(result.cues[0].identifier == "1")
        #expect(result.cues[0].startMilliseconds == 1000)
        #expect(result.cues[0].endMilliseconds == 3000)
        #expect(result.cues[0].rawText == "Hello")
        #expect(slice(srtTwoCues, result.cues[0].textRange) == "Hello")
        #expect(result.cues[1].rawText == "World")
        #expect(slice(srtTwoCues, result.cues[1].textRange) == "World")
        #expect(result.hasCueIndexes)
        #expect(result.errorCount == 0)
    }

    @Test("Accepts missing indexes and multiline text")
    func optionalIndexAndMultilineText() {
        let source = """
        00:00:01,000 --> 00:00:02,000
        Line one
        Line two

        00:00:03,000 --> 00:00:04,000
        Next
        """
        let result = parseSRT(source)
        #expect(result.cues.count == 2)
        #expect(!result.hasCueIndexes)
        #expect(result.cues[0].rawText == "Line one\nLine two")
        #expect(result.cues[1].rawText == "Next")
    }

    @Test("Keeps SRT coordinate lines out of the text")
    func coordinateLine() {
        let source = """
        1
        00:00:01,000 --> 00:00:02,000
        X1:10 X2:20 Y1:30 Y2:40
        Hello
        """
        let result = parseSRT(source)
        #expect(result.cues.count == 1)
        #expect(result.cues[0].coordinateLine != nil)
        #expect(result.cues[0].rawText == "Hello")
        #expect(slice(source, result.cues[0].textRange) == "Hello")
    }

    @Test("Reports malformed blocks without dropping them")
    func malformedBlock() {
        let source = """
        1
        not a timestamp
        Hello

        2
        00:00:03,000 --> 00:00:05,000
        World
        """
        let result = parseSRT(source)
        #expect(result.cues.count == 1)
        #expect(result.cues[0].rawText == "World")
        #expect(result.unparsedBlocks.count == 1)
        #expect(result.unparsedBlocks[0].text.contains("not a timestamp"))
        #expect(result.errorCount == 1)
    }

    @Test("Flags invalid timing, empty text, and overlap")
    func diagnostics() {
        let source = """
        1
        00:00:02,000 --> 00:00:01,000
        Backwards

        2
        00:00:01,000 --> 00:00:02,000
        First

        3
        00:00:01,500 --> 00:00:03,000
        Overlapping

        4
        00:00:04,000 --> 00:00:05,000
        """
        let result = parseSRT(source)
        #expect(result.cues.count == 4)
        let kinds = Set(result.diagnostics.map(\.kind))
        #expect(kinds.contains(.endNotAfterStart))
        #expect(kinds.contains(.overlappingCue(previousOrdinal: 1)))
        #expect(kinds.contains(.emptyText))
    }

    @Test("Parses a file with only whitespace without crashing")
    func emptySource() {
        let result = parseSRT("")
        #expect(result.cues.isEmpty)
        #expect(result.diagnostics.isEmpty)
        #expect(result.timeline.durationMilliseconds == 0)
    }
}

@Suite("WebVTT parsing")
struct WebVTTParsingTests {
    @Test("Skips header, NOTE, and STYLE blocks")
    func headerAndMetadata() {
        let source = """
        WEBVTT - Demo

        NOTE This is a note
        that spans lines

        STYLE
        ::cue { color: yellow }

        00:00:01.000 --> 00:00:02.000 align:start
        Hello

        cue-id
        00:00:03.000 --> 00:00:04.000
        World
        """
        let result = parseVTT(source)
        #expect(result.cues.count == 2)
        #expect(result.cues[0].identifier == nil)
        #expect(result.cues[0].settings == "align:start")
        #expect(result.cues[1].identifier == "cue-id")
        #expect(result.cues[1].rawText == "World")
        #expect(result.errorCount == 0)
    }

    @Test("Accepts hourless timestamps")
    func hourless() {
        let source = """
        WEBVTT

        01:02.500 --> 01:03.000
        Short
        """
        let result = parseVTT(source)
        #expect(result.cues.count == 1)
        #expect(result.cues[0].startMilliseconds == 62_500)
        #expect(result.cues[0].endMilliseconds == 63_000)
    }

    @Test("Warns about a missing header and duplicate identifiers")
    func warnings() {
        let source = """
        00:00:01.000 --> 00:00:02.000
        One

        same
        00:00:03.000 --> 00:00:04.000
        Two

        same
        00:00:05.000 --> 00:00:06.000
        Three
        """
        let result = parseVTT(source)
        #expect(result.cues.count == 3)
        let kinds = Set(result.diagnostics.map(\.kind))
        #expect(kinds.contains(.duplicateIndex("same")))
        #expect(
            result.diagnostics.contains {
                if case .malformedBlock = $0.kind { return true }
                return false
            }
        )
    }

    @Test("Keeps cue text tags raw")
    func rawTags() {
        let result = parseVTT(
            "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<v Alice>Hello</v>"
        )
        #expect(result.cues[0].rawText == "<v Alice>Hello</v>")
    }
}

@Suite("ASS parsing")
struct ASSParsingTests {
    @Test("Uses the Events Format line and keeps commas in text")
    func formatDrivenFields() {
        let result = parseASS(assSample)
        #expect(result.cues.count == 1)
        let cue = result.cues[0]
        #expect(cue.startMilliseconds == 1000)
        #expect(cue.endMilliseconds == 3000)
        #expect(cue.rawText == "Hello, {\\i1}world{\\i0}!")
        #expect(cue.style == "Default")
        #expect(slice(assSample, cue.textRange) == cue.rawText)
        #expect(slice(assSample, cue.startRange!) == "0:00:01.00")
        #expect(result.assInfo?.defaultStyle == "Default")
        #expect(result.assInfo?.formatFields.first == "layer")
    }

    @Test("Detects SSA's legacy style section")
    func ssaIdentity() {
        let source = """
        [Script Info]
        ScriptType: v4.00

        [V4 Styles]
        Format: Name, Fontname
        Style: Default,Arial

        [Events]
        Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: Marked=0,0:00:01.00,0:00:02.00,Default,,0000,0000,0000,,Hi
        """
        let result = parseASS(source, format: .ssa)
        #expect(result.format == .ssa)
        #expect(result.cues.count == 1)
        #expect(result.cues[0].rawText == "Hi")
    }

    @Test("Reports a missing Format line and malformed dialogues")
    func missingFormat() {
        let source = """
        [Script Info]
        Title: Broken

        [Events]
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0000,0000,0000,,Hi
        """
        let result = parseASS(source)
        #expect(result.cues.isEmpty)
        #expect(result.assInfo?.formatFields == [])
        #expect(
            result.diagnostics.contains {
                $0.kind == .missingFormatLine
            }
        )
        #expect(result.errorCount > 0)
    }

    @Test("Ignores non-Dialogue event lines")
    func commentsAndCommands() {
        let result = parseASS(
            assSample + "\nComment: 0,0:00:02.00,0:00:03.00,"
                + "Default,,0000,0000,0000,,Note\n"
        )
        #expect(result.cues.count == 1)
        #expect(result.cues[0].rawText.contains("world"))
    }
}

@Suite("Subtitle timeline")
struct SubtitleTimelineTests {
    private func timeline(_ source: String) -> SubtitleTimeline {
        parseSRT(source).timeline
    }

    @Test("Active cues are start-inclusive and end-exclusive")
    func activeCues() {
        let timeline = timeline(
            """
            1
            00:00:01,000 --> 00:00:03,000
            One

            2
            00:00:02,000 --> 00:00:04,000
            Two

            3
            00:00:05,000 --> 00:00:06,000
            Three
            """
        )
        #expect(timeline.durationMilliseconds == 6000)
        #expect(timeline.activeOrdinals(atMilliseconds: 999).isEmpty)
        #expect(timeline.activeOrdinals(atMilliseconds: 1000) == [0])
        #expect(timeline.activeOrdinals(atMilliseconds: 2500) == [0, 1])
        #expect(timeline.activeOrdinals(atMilliseconds: 3000) == [1])
        #expect(timeline.activeOrdinals(atMilliseconds: 4000).isEmpty)
        #expect(timeline.activeOrdinals(atMilliseconds: 5000) == [2])
        #expect(timeline.activeOrdinals(atMilliseconds: 6000).isEmpty)
    }

    @Test("Negative and invalid cues never become active")
    func invalidCues() {
        let timeline = timeline(
            """
            1
            00:00:02,000 --> 00:00:01,000
            Backwards
            """
        )
        #expect(timeline.activeOrdinals(atMilliseconds: 1500).isEmpty)
        #expect(timeline.durationMilliseconds == 0)
    }
}

@Suite("Subtitle preview text")
struct SubtitleTextTests {
    @Test("Strips ASS overrides and translates line breaks")
    func assText() {
        let raw = "{\\i1}Hello{\\i0}\\Nworld\\hagain"
        #expect(SubtitleText.plainText(raw, format: .ass) == "Hello\nworld again")
    }

    @Test("Strips markup and decodes entities for SRT and VTT")
    func markupText() {
        let raw = "<i>Hello</i> &amp; <b>world</b> &#33;"
        #expect(
            SubtitleText.plainText(raw, format: .srt) == "Hello & world !"
        )
        #expect(
            SubtitleText.plainText(raw, format: .vtt) == "Hello & world !"
        )
    }
}

@Suite("Subtitle encoding")
struct SubtitleEncodingTests {
    @Test("Decodes UTF-8 with and without a BOM")
    func utf8() throws {
        let plain = try SubtitleEncoding.decode(Data("a\r\nb\r\n".utf8))
        #expect(plain.text == "a\nb\n")
        #expect(plain.encoding == .utf8(hasBOM: false))
        #expect(plain.lineEnding == .crlf)

        var bom = Data([0xEF, 0xBB, 0xBF])
        bom.append(Data("hello".utf8))
        let withBOM = try SubtitleEncoding.decode(bom)
        #expect(withBOM.text == "hello")
        #expect(withBOM.encoding == .utf8(hasBOM: true))
    }

    @Test("Decodes and re-encodes UTF-16 LE and BE")
    func utf16() throws {
        var le = Data([0xFF, 0xFE])
        le.append(Data("hi".utf16.flatMap {
            [UInt8($0 & 0xFF), UInt8($0 >> 8)]
        }))
        let leContents = try SubtitleEncoding.decode(le)
        #expect(leContents.text == "hi")
        #expect(leContents.encoding == .utf16LittleEndian)
        let leBytes = try SubtitleEncoding.encode(
            "hi\n",
            encoding: .utf16LittleEndian,
            lineEnding: .crlf
        )
        #expect(leBytes.prefix(2) == Data([0xFF, 0xFE]))
        #expect(try SubtitleEncoding.decode(leBytes).text == "hi\n")

        var be = Data([0xFE, 0xFF])
        be.append(contentsOf: [0x00, 0x68, 0x00, 0x69])
        let beContents = try SubtitleEncoding.decode(be)
        #expect(beContents.text == "hi")
        #expect(beContents.encoding == .utf16BigEndian)
    }

    @Test("Falls back to Windows-1252 and preserves it")
    func windows1252() throws {
        // 0xE9 is é in CP1252 and invalid on its own as UTF-8.
        let data = Data([0x43, 0x61, 0x66, 0xE9])
        let contents = try SubtitleEncoding.decode(data)
        #expect(contents.text == "Café")
        #expect(contents.encoding == .windows1252)

        let encoded = try SubtitleEncoding.encode(
            contents.text,
            encoding: .windows1252,
            lineEnding: .lf
        )
        #expect(encoded == data)
    }

    @Test("Rejects binary data and UTF-32")
    func rejections() {
        #expect(throws: SubtitleEncodingError.invalidEncoding) {
            _ = try SubtitleEncoding.decode(Data([0x00, 0x01, 0x00, 0x02]))
        }
        #expect(throws: SubtitleEncodingError.unsupportedUTF32) {
            _ = try SubtitleEncoding.decode(
                Data([0xFF, 0xFE, 0x00, 0x00])
            )
        }
    }

    @Test("Round-trips BOM and CRLF")
    func roundTrip() throws {
        let bytes = try SubtitleEncoding.encode(
            "a\nb\n",
            encoding: .utf8(hasBOM: true),
            lineEnding: .crlf
        )
        #expect(bytes.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
        #expect(bytes.range(of: Data([0x0D, 0x0A])) != nil)
        let decoded = try SubtitleEncoding.decode(bytes)
        #expect(decoded.text == "a\nb\n")
        #expect(decoded.encoding == .utf8(hasBOM: true))
    }
}
