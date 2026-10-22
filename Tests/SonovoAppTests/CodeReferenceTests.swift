import XCTest
@testable import Sonovo

final class CodeReferenceTests: XCTestCase {
    private func delivery(
        send: ((String) -> Bool)?,
        clipboard: @escaping (String) -> Void = { _ in }
    ) -> CodeReferenceDelivery {
        CodeReferenceDelivery(send: send, copy: clipboard)
    }

    func testSanitizerStripsControlCharactersAndNewlines() {
        XCTAssertEqual(
            CodeReferenceDelivery.sanitized("Sources/a.swift:3:7"),
            "Sources/a.swift:3:7"
        )
        XCTAssertEqual(
            CodeReferenceDelivery.sanitized(
                "path with spaces:1:1"
            ),
            "path with spaces:1:1"
        )
        XCTAssertEqual(
            CodeReferenceDelivery.sanitized(
                "a.swift:1:1\nrm -rf /\u{1B}[31m"
            ),
            "a.swift:1:1rm -rf /[31m"
        )
        XCTAssertNil(CodeReferenceDelivery.sanitized("\n\t\u{1B}"))
    }

    func testTerminalReceivesOneLineAndNeverEnter() {
        var received: [String] = []
        let result = delivery(send: { text in
            received.append(text)
            return true
        }).deliver(reference: "a.swift:2:3", multiline: false)
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(received, ["a.swift:2:3"])
        XCTAssertFalse(received[0].contains("\n"))
    }

    func testSpacesAndQuotesArePreserved() {
        var received: [String] = []
        let reference = "My Files/it's \"quoted\".swift:1:1"
        let result = delivery(send: { text in
            received.append(text)
            return true
        }).deliver(reference: reference, multiline: false)
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(received.first, reference)
    }

    func testMultilineSelectionGoesToClipboardOnly() {
        var copied: [String] = []
        var sent = false
        let result = delivery(
            send: { _ in
                sent = true
                return true
            },
            clipboard: { copied.append($0) }
        ).deliver(reference: "a\nb", multiline: true)
        XCTAssertEqual(result, .copied)
        XCTAssertFalse(sent)
        XCTAssertEqual(copied, ["a\nb"])
    }

    func testAbsentOrHiddenTerminalFallsBackToTheClipboard() {
        var copied: [String] = []
        let hidden = delivery(send: nil, clipboard: {
            copied.append($0)
        }).deliver(reference: "a.swift:1:1", multiline: false)
        XCTAssertEqual(hidden, .copied)

        // A sink that refuses represents a session that is gone or belongs
        // to another project by the time the reference is delivered.
        let switched = delivery(
            send: { _ in false },
            clipboard: { copied.append($0) }
        ).deliver(reference: "a.swift:1:2", multiline: false)
        XCTAssertEqual(switched, .copied)
        XCTAssertEqual(
            copied,
            ["a.swift:1:1", "a.swift:1:2"]
        )
    }

    func testControlOnlyReferenceIsRejected() {
        var copied: [String] = []
        let result = delivery(
            send: { _ in true },
            clipboard: { copied.append($0) }
        ).deliver(reference: "\n\t\u{1B}", multiline: false)
        XCTAssertEqual(result, .rejected)
        XCTAssertTrue(copied.isEmpty)
    }
}
