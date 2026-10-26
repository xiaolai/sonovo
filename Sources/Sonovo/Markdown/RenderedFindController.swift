import Foundation
import Observation
import SonovoCore

/// Find state for the rendered reading view. The source editor keeps the
/// native find bar; the view gets this bar so Cmd+F is never a dead key.
@MainActor
@Observable
final class RenderedFindController {
    var isVisible = false
    var query = ""
    private(set) var matches: [MarkdownRenderedMatch] = []
    private(set) var currentIndex = 0
    /// Bumped on every `show()` so a second Cmd+F refocuses the field even
    /// when the bar is already open.
    private(set) var focusRequest = 0

    var current: MarkdownRenderedMatch? {
        guard matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    var countLabel: String {
        if query.isEmpty { return "" }
        guard !matches.isEmpty else { return "No matches" }
        return "\(currentIndex + 1) of \(matches.count)"
    }

    func show() {
        isVisible = true
        focusRequest &+= 1
    }

    func close() {
        isVisible = false
    }

    func setMatches(_ newMatches: [MarkdownRenderedMatch]) {
        matches = newMatches
        if newMatches.isEmpty {
            currentIndex = 0
        } else if currentIndex >= newMatches.count {
            currentIndex = newMatches.count - 1
        }
    }

    func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let count = matches.count
        currentIndex = ((currentIndex + delta) % count + count) % count
    }
}
