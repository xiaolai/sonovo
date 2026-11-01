import SonovoDomainTypes
import SonovoWorkspaceHost

extension ProjectScanner {
    init(limits: Limits = Limits()) {
        self.init(catalogue: BuiltInFeatureComposition.catalogue, limits: limits)
    }
    static func kind(forExtension fileExtension: String) -> AssetKind? {
        guard !fileExtension.contains(".") else { return nil }
        return BuiltInFeatureComposition.catalogue.resolve("fixture." + fileExtension)?.kind
    }

    static func kind(forFilename name: String) -> AssetKind? {
        BuiltInFeatureComposition.catalogue.resolve(name)?.kind
    }

}
