import WebKit

/// A process-wide cache for the content rule list that blocks every external
/// scheme before a request can leave the web view.
@MainActor
package enum ModelContentRules {
    private static let identifier = "sonovo.model.block-external.v1"
    private static var cached: WKContentRuleList?
    private static var pending: Task<WKContentRuleList?, Never>?

    private static let encodedRules = """
    [
      {"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^file://"},"action":{"type":"block"}}
    ]
    """

    package static func ruleList() async -> WKContentRuleList? {
        if let cached {
            return cached
        }
        if let pending {
            return await pending.value
        }

        let task = Task<WKContentRuleList?, Never> { @MainActor in
            await withCheckedContinuation { continuation in
                WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: identifier,
                    encodedContentRuleList: encodedRules
                ) { list, _ in
                    continuation.resume(returning: list)
                }
            }
        }
        pending = task
        let list = await task.value
        pending = nil
        cached = list
        return list
    }
}
