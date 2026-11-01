import Foundation

package enum DocumentSelector: Equatable, Sendable {
    case fileExtension(String)
    case fileName(String)
    case filePrefix(String)
    case fileSuffix(String)

    package var isValid: Bool {
        let value: String
        switch self {
        case .fileExtension(let ext):
            guard !ext.contains(".") else { return false }
            value = ext
        case .fileName(let name): value = name
        case .filePrefix(let prefix): value = prefix
        case .fileSuffix(let suffix):
            guard suffix.hasPrefix("."), suffix.count > 1 else { return false }
            value = suffix
        }
        return !value.isEmpty && !value.contains("/") && !value.contains("\\")
    }

    package func matches(_ fileName: String) -> Bool {
        let name = fileName.lowercased()
        switch self {
        case .fileExtension(let ext): return (name as NSString).pathExtension == ext.lowercased()
        case .fileName(let expected): return fileName == expected
        case .fileSuffix(let suffix): return name.hasSuffix(suffix.lowercased())
        case .filePrefix(let prefix): return fileName.hasPrefix(prefix)
        }
    }

    package func overlaps(_ other: DocumentSelector) -> Bool {
        switch (self, other) {
        case (.fileExtension(let a), .fileExtension(let b)): return a.lowercased() == b.lowercased()
        case (.fileName(let name), _): return other.matches(name)
        case (_, .fileName(let name)): return matches(name)
        case (.filePrefix(let a), .filePrefix(let b)):
            return a.hasPrefix(b) || b.hasPrefix(a)
        case (.filePrefix, _), (_, .filePrefix): return true
        case (.fileSuffix(let a), .fileSuffix(let b)):
            return a.lowercased().hasSuffix(b.lowercased()) || b.lowercased().hasSuffix(a.lowercased())
        case (.fileExtension(let ext), .fileSuffix(let suffix)), (.fileSuffix(let suffix), .fileExtension(let ext)):
            return (("file" + suffix) as NSString).pathExtension.lowercased() == ext.lowercased()
        }
    }
}

/// Pure metadata; scanners can retain it even when no executable factory is
/// available. Declared overrides replace registration-order priority guesses.
package struct DocumentProviderDescriptor: Equatable, Sendable {
    package let id: EditorProviderID
    package let featureID: FeatureID
    package let kind: AssetKind
    package let selectors: [DocumentSelector]
    package let overrides: Set<EditorProviderID>

    package init(
        id: EditorProviderID, featureID: FeatureID, kind: AssetKind,
        selectors: [DocumentSelector], overrides: Set<EditorProviderID> = []
    ) {
        self.id = id
        self.featureID = featureID
        self.kind = kind
        self.selectors = selectors
        self.overrides = overrides
    }
}
