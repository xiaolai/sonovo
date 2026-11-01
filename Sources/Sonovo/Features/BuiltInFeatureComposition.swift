import SonovoTerminalFeature
import SonovoMediaEngine
import SonovoMediaFeature
import SonovoTimelineFeature
import SonovoModel3DFeature
import SonovoSubtitleFeature
import SonovoMDXFeature
import SonovoMarkdownFeature
import SonovoCodeFeature
import SonovoTextEngine
import Foundation
import SwiftUI
import SonovoMarkdownEngine
import SonovoSubtitleEngine
import SonovoDomainTypes
import SonovoFeatureAPI
import SonovoWorkspaceHost
import SonovoViewerFeature

/// The app chooses built-ins; the host sees metadata and contributions only.
@MainActor enum BuiltInFeatureComposition {
    nonisolated static let metadata: [FeatureMetadata] = {
        let dedicated = [ViewerFeature.metadata, MarkdownFeature.metadata, SubtitleFeature.metadata,
                         Model3DFeature.metadata, MediaFeature.metadata]
        let overridden = Set(dedicated.flatMap(\.documentProviders).map(\.id))
        return dedicated + [CodeFeature.metadata(overriding: overridden), MDXFeature.metadata,
                            TimelineFeature.metadata, TerminalFeature.metadata]
    }()
    nonisolated static let descriptors = metadata.flatMap(\.documentProviders)
    nonisolated static let catalogue: DocumentRecognitionCatalogue = {
        do { return try DocumentRecognitionCatalogue(descriptors) }
        catch { preconditionFailure("Invalid built-in document catalogue: \(error)") }
    }()
    static func makeSessions(code: CodeWorkspace, markdown: MarkdownWorkspace, subtitles: SubtitleWorkspace,
                             mdx: MDXWorkspace, models: Model3DWorkspace, timelines: TimelineWorkspace,
                             mediaEdits: MediaEditWorkspace, terminalSessions: TerminalSessionsStore) -> FeatureSessionRegistry {
        let sessions: [any ProjectFeatureSession] = [
            MarkdownFeatureSession(workspace: markdown), SubtitleFeatureSession(workspace: subtitles),
            Model3DFeatureSession(workspace: models), CodeFeatureSession(workspace: code), MDXFeatureSession(workspace: mdx),
            ViewerFeatureSession(), MediaFeatureSession(workspace: mediaEdits), TimelineFeatureSession(workspace: timelines),
            TerminalFeatureSession(workspace: terminalSessions)
        ]
        do { return try FeatureSessionRegistry(metadata: metadata, sessions: sessions) }
        catch { preconditionFailure("Invalid built-in feature sessions: \(error)") }
    }
}
