import Foundation

enum AppVersion {
    static let current: String = {
        guard let url = Bundle.module.url(forResource: "version", withExtension: "txt"),
              let value = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return "unknown"
        }
        return value
    }()
}
