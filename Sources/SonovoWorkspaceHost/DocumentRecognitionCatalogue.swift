import Foundation
import SonovoDomainTypes

package enum DocumentRecognitionError: Error, Equatable {
    case invalidDescriptor(EditorProviderID)
    case duplicateProvider(EditorProviderID)
    case unknownOverride(EditorProviderID, EditorProviderID)
    case overrideCycle(EditorProviderID)
    case overlappingProviders(EditorProviderID, EditorProviderID)
}

/// Immutable and Sendable. Resolving a name cannot instantiate a feature or
/// require a main-actor hop, a content read, or an executable editor factory.
package struct DocumentRecognitionCatalogue: Sendable {
    package let descriptors: [DocumentProviderDescriptor]
    private let transitiveOverrides: [EditorProviderID: Set<EditorProviderID>]

    package init(_ descriptors: [DocumentProviderDescriptor]) throws {
        var byID: [EditorProviderID: DocumentProviderDescriptor] = [:]
        for descriptor in descriptors {
            guard descriptor.id.isValid, descriptor.featureID.isValid,
                  !descriptor.selectors.isEmpty, descriptor.selectors.allSatisfy(\.isValid) else {
                throw DocumentRecognitionError.invalidDescriptor(descriptor.id)
            }
            guard byID.updateValue(descriptor, forKey: descriptor.id) == nil else {
                throw DocumentRecognitionError.duplicateProvider(descriptor.id)
            }
        }
        var resolved: [EditorProviderID: Set<EditorProviderID>] = [:]
        func descendants(_ id: EditorProviderID, visiting: Set<EditorProviderID>) throws -> Set<EditorProviderID> {
            if let cached = resolved[id] { return cached }
            guard !visiting.contains(id) else { throw DocumentRecognitionError.overrideCycle(id) }
            guard let descriptor = byID[id] else { return [] }
            var result = Set<EditorProviderID>()
            for child in descriptor.overrides.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard byID[child] != nil else { throw DocumentRecognitionError.unknownOverride(id, child) }
                result.insert(child)
                result.formUnion(try descendants(child, visiting: visiting.union([id])))
            }
            resolved[id] = result
            return result
        }
        for descriptor in descriptors { _ = try descendants(descriptor.id, visiting: []) }
        for (index, first) in descriptors.enumerated() {
            for second in descriptors.dropFirst(index + 1) {
                let overlap = first.selectors.contains { a in second.selectors.contains { a.overlaps($0) } }
                guard !overlap || resolved[first.id, default: []].contains(second.id)
                        || resolved[second.id, default: []].contains(first.id) else {
                    throw DocumentRecognitionError.overlappingProviders(first.id, second.id)
                }
            }
        }
        self.descriptors = descriptors
        transitiveOverrides = resolved
    }

    package func resolve(_ fileName: String) -> DocumentProviderDescriptor? {
        let matches = descriptors.filter { $0.selectors.contains { $0.matches(fileName) } }
        return matches.first { candidate in
            !matches.contains { other in
                transitiveOverrides[other.id, default: []].contains(candidate.id)
            }
        }
    }
}
