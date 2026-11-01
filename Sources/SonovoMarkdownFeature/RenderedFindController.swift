import Foundation
import Observation
import SonovoMarkdownEngine

/// Find state for the rendered reading view. The source editor keeps the
/// native find bar; the view gets this bar so Cmd+F is never a dead key.
@MainActor
@Observable
package final class RenderedFindController {
    package var isVisible = false
    package var query = ""
    package private(set) var matches: [MarkdownRenderedMatch] = []
    package private(set) var currentIndex = 0
    /// Bumped on every `show()` so a second Cmd+F refocuses the field even
    /// when the bar is already open.
    package private(set) var focusRequest = 0

    package var current: MarkdownRenderedMatch? {
        guard matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    package var countLabel: String {
        if query.isEmpty { return "" }
        guard !matches.isEmpty else { return "No matches" }
        return "\(currentIndex + 1) of \(matches.count)"
    }

    package func show() {
        isVisible = true
        focusRequest &+= 1
    }

    package func close() {
        isVisible = false
    }

    package func setMatches(_ newMatches: [MarkdownRenderedMatch]) {
        matches = newMatches
        if newMatches.isEmpty {
            currentIndex = 0
        } else if currentIndex >= newMatches.count {
            currentIndex = newMatches.count - 1
        }
    }

    package func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let count = matches.count
        currentIndex = ((currentIndex + delta) % count + count) % count
    }
}
