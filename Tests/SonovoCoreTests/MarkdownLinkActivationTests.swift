import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown link activation")
struct MarkdownLinkActivationTests {
    @Test("Web and mail links ask before leaving the app")
    func externalLinksAsk() {
        for destination in [
            "https://example.com/a",
            "http://example.com",
            "mailto:someone@example.com"
        ] {
            guard case let .confirmBeforeOpening(url) =
                MarkdownLinkActivation.decide(destination) else {
                Issue.record("\(destination) did not ask")
                continue
            }
            #expect(url.absoluteString == destination)
        }
    }

    @Test("Fragments and local paths open directly")
    func directLinks() {
        #expect(
            MarkdownLinkActivation.decide("#section")
                == .openDirectly(.fragment)
        )
        #expect(
            MarkdownLinkActivation.decide("notes/other.md")
                == .openDirectly(.local)
        )
    }

    @Test("The allowlist still refuses unsafe schemes first")
    func refusedLinks() {
        for destination in [
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "file:///etc/passwd",
            "//example.com/path",
            "sonovo:Note",
            ""
        ] {
            guard case .refused = MarkdownLinkActivation.decide(destination)
            else {
                Issue.record("\(destination) was not refused")
                continue
            }
        }
    }

    @Test("Surrounding whitespace does not change the decision")
    func trimsWhitespace() {
        #expect(
            MarkdownLinkActivation.decide("  https://example.com  ")
                == .confirmBeforeOpening(URL(string: "https://example.com")!)
        )
    }
}
