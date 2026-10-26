import Foundation

/// A validated `sonovo:` media reference authored as an ordinary Markdown
/// link.
///
/// ```
/// [Opening](sonovo:timecode?path=edit/master.mov&t=00:12:34.5)
/// [Take 2](sonovo:take?path=edit/take-2.mov&seconds=12.5&label=Take%202)
/// ```
///
/// Both forms accept `path`, `seconds`, `t`, and `label`. A `timecode` link
/// needs a time (`seconds` or `t`); a `take` link may omit it. An absent
/// `path` targets the project's currently selected media asset. Unknown
/// query keys, duplicate keys, unsafe paths, and unknown kinds are refused
/// outright rather than guessed at.
public struct MediaReference: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case timecode
        case take
    }

    public static let scheme = "sonovo"

    public let kind: Kind
    /// A validated document-relative path, or nil for the current transport.
    public let path: String?
    /// Non-negative seconds into the media, when one was authored.
    public let seconds: Double?
    /// An optional display label; the link's own text is the usual label.
    public let label: String?

    public init(
        kind: Kind,
        path: String?,
        seconds: Double?,
        label: String?
    ) {
        self.kind = kind
        self.path = path
        self.seconds = seconds
        self.label = label
    }

    /// Parses a complete destination. Returns nil for anything invalid.
    public static func parse(_ destination: String) -> MediaReference? {
        let trimmed = destination.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed.count > scheme.count,
              trimmed.prefix(scheme.count).lowercased() == scheme else {
            return nil
        }
        var rest = trimmed.dropFirst(scheme.count)
        guard rest.first == ":" else { return nil }
        rest = rest.dropFirst()

        // Accept the documented `sonovo:timecode?...` spelling and the
        // URL-authority spelling `sonovo://timecode?...` alike.
        while rest.hasPrefix("/") {
            rest = rest.dropFirst()
        }
        let parts = rest.split(
            separator: "?",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let kind = Kind(rawValue: String(parts[0]).lowercased()) else {
            return nil
        }

        var path: String?
        var seconds: Double?
        var label: String?
        var sawTime = false
        var sawLabel = false

        if parts.count == 2 {
            for item in parts[1].split(
                separator: "&",
                omittingEmptySubsequences: true
            ) {
                let pair = item.split(
                    separator: "=",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                guard pair.count == 2,
                      let key = String(pair[0]).removingPercentEncoding,
                      let value = String(pair[1]).removingPercentEncoding
                else {
                    return nil
                }
                switch key {
                case "path":
                    guard path == nil,
                          MarkdownSecurity.isValidRelativePath(value) else {
                        return nil
                    }
                    path = value
                case "seconds":
                    guard !sawTime,
                          let parsed = Double(value),
                          parsed.isFinite,
                          parsed >= 0 else {
                        return nil
                    }
                    seconds = parsed
                    sawTime = true
                case "t":
                    guard !sawTime,
                          let parsed = timecodeSeconds(value) else {
                        return nil
                    }
                    seconds = parsed
                    sawTime = true
                case "label":
                    // Duplicate keys are refused even when the first value
                    // was empty, or `label=&label=x` slips through.
                    guard !sawLabel else { return nil }
                    sawLabel = true
                    label = value.isEmpty ? nil : value
                default:
                    return nil
                }
            }
        }

        if kind == .timecode, !sawTime {
            return nil
        }
        return MediaReference(
            kind: kind,
            path: path,
            seconds: seconds,
            label: label
        )
    }

    /// The canonical percent-encoded destination for this reference.
    public func url() -> URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.path = kind.rawValue
        var items: [URLQueryItem] = []
        if let path {
            items.append(URLQueryItem(name: "path", value: path))
        }
        if let seconds {
            items.append(
                URLQueryItem(name: "seconds", value: String(seconds))
            )
        }
        if let label {
            items.append(URLQueryItem(name: "label", value: label))
        }
        if !items.isEmpty {
            components.queryItems = items
        }
        return components.url
    }

    /// Parses `H:MM:SS(.fff)` or `M:SS(.fff)`. Minutes and seconds must be
    /// below sixty; only the leading component may be unbounded.
    public static func timecodeSeconds(_ value: String) -> Double? {
        let parts = value.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var numbers: [Double] = []
        for part in parts {
            guard !part.isEmpty,
                  let number = Double(part),
                  number.isFinite else {
                return nil
            }
            numbers.append(number)
        }
        let total: Double
        if numbers.count == 3 {
            let (hours, minutes, seconds) = (
                numbers[0], numbers[1], numbers[2]
            )
            guard hours >= 0,
                  minutes >= 0, minutes < 60,
                  seconds >= 0, seconds < 60 else {
                return nil
            }
            total = hours * 3600 + minutes * 60 + seconds
        } else {
            let (minutes, seconds) = (numbers[0], numbers[1])
            guard minutes >= 0, seconds >= 0, seconds < 60 else {
                return nil
            }
            total = minutes * 60 + seconds
        }
        // A finite component can still overflow the sum (`1e308:00` would
        // become infinite seconds) and pass every earlier check.
        return total.isFinite ? total : nil
    }
}
