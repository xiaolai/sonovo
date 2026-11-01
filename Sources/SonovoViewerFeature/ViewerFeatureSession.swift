import SonovoDomainTypes
import SonovoFeatureAPI

@MainActor package final class ViewerFeatureSession: ProjectFeatureSession {
    package let featureID: FeatureID = "builtin.viewer"
    package let editors: [FeatureEditorContribution]
    package var lifecycle = FeatureLifecycle()
    package init() { self.editors = ViewerFeature.editors }
}
