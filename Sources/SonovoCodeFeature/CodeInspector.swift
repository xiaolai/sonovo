import SwiftUI
import SonovoDomainTypes
import SonovoDesignSystem
import SonovoFileIO

struct CodeInspector: View {
    let workspace: CodeWorkspace
    let asset: ProjectAsset
    var body: some View {
        if asset.kind == .code,
           let document = workspace.selectedDocument,
           FilePathPolicy.canonical(document.fileURL)
            == FilePathPolicy.canonical(asset.url) {
            InspectorSection("Code") {
                MetadataRow(
                    label: "Language",
                    value: document.language.displayName
                )
                if document.isReady {
                    MetadataRow(
                        label: "Lines",
                        value: "\(document.source.components(separatedBy: "\n").count)"
                    )
                    MetadataRow(
                        label: "Encoding",
                        value: document.hasBOM ? "UTF-8 BOM" : "UTF-8"
                    )
                    MetadataRow(
                        label: "Line endings",
                        value: document.lineEnding == .crlf ? "CRLF" : "LF"
                    )
                }
                MetadataRow(
                    label: "State",
                    value: codeStateLabel(document)
                )
            }
        }
    }

    private func codeStateLabel(_ document: CodeDocument) -> String {
        if let refusal = document.refusal {
            return refusal.explanation
        }
        if !document.isReady {
            return "Loading"
        }
        if let reason = document.readOnlyReason {
            return reason.explanation
        }
        if document.isDirty {
            return "Unsaved changes"
        }
        if document.pendingReview {
            return "Changed on disk"
        }
        return "Ready"
    }

}
