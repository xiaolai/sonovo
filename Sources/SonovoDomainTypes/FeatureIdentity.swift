/// Runtime identities are distinct from file paths, revisions and documents.
/// They are not persisted by the current workspace preference schema.
package struct FeatureID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    package let rawValue: String
    package init(rawValue: String) { self.rawValue = rawValue }
    package init(stringLiteral value: String) { rawValue = value }
    package var isValid: Bool { validNamespacedID(rawValue) }
}

package struct EditorProviderID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    package let rawValue: String
    package init(rawValue: String) { self.rawValue = rawValue }
    package init(stringLiteral value: String) { rawValue = value }
    package var isValid: Bool { validNamespacedID(rawValue) }
}

private func validNamespacedID(_ value: String) -> Bool {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count >= 2 && parts.allSatisfy { part in
        !part.isEmpty && part.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}
