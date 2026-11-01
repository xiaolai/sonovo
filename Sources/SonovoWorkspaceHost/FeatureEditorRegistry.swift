import SonovoDomainTypes
import SonovoFeatureAPI

package enum FeatureEditorRegistrationError: Error, Equatable {
    case duplicateFactory(EditorProviderID)
    case unrecognizedFactory(EditorProviderID)
}

@MainActor
package final class FeatureEditorRegistry {
    package let catalogue: DocumentRecognitionCatalogue
    private let contributions: [EditorProviderID: FeatureEditorContribution]

    package init(catalogue: DocumentRecognitionCatalogue, contributions: [FeatureEditorContribution]) throws {
        let known = Set(catalogue.descriptors.map(\.id))
        var registered: [EditorProviderID: FeatureEditorContribution] = [:]
        for contribution in contributions {
            guard known.contains(contribution.id) else {
                throw FeatureEditorRegistrationError.unrecognizedFactory(contribution.id)
            }
            guard registered.updateValue(contribution, forKey: contribution.id) == nil else {
                throw FeatureEditorRegistrationError.duplicateFactory(contribution.id)
            }
        }
        self.catalogue = catalogue
        self.contributions = registered
    }

    package func contribution(for id: EditorProviderID) -> FeatureEditorContribution? {
        contributions[id]
    }
}
