import Foundation
import SwiftUI
import SonovoDomainTypes

package enum FeatureCommandRole: Sendable { case find, findNext, findPrevious, replace, replaceAll, record }

@MainActor package struct FeatureMenuContext {
    package let isEditorSelected: Bool
    package let isEditorVisible: Bool
    package let perform: (String) -> Void
    package init(isEditorSelected: Bool, isEditorVisible: Bool, perform: @escaping (String) -> Void) {
        self.isEditorSelected = isEditorSelected; self.isEditorVisible = isEditorVisible; self.perform = perform
    }
}
@MainActor package struct FeatureMenuContribution {
    package let title: String
    package let makeView: (FeatureMenuContext) -> AnyView
    package init(title: String, makeView: @escaping (FeatureMenuContext) -> AnyView) {
        self.title = title; self.makeView = makeView
    }
}

/// An invocation captures the live project synchronously. A feature captures
/// its selected document before calling reveal, which may change selection.
@MainActor package struct FeatureCommandInvocation {
    package var project: (any EditorProjectContext)?
    package var revealWorkspace: () -> Void
    package var revealDocument: (WorkspaceDocumentReference) -> Void
    package var reportError: (String, String) -> Void
    package var mediaReplaceRequests: (any MediaReplaceRequestSource)?
    package init(project: (any EditorProjectContext)? = nil, revealWorkspace: @escaping () -> Void = {},
                 revealDocument: @escaping (WorkspaceDocumentReference) -> Void = { _ in },
                 reportError: @escaping (String, String) -> Void = { _, _ in },
                 mediaReplaceRequests: (any MediaReplaceRequestSource)? = nil) {
        self.project = project; self.revealWorkspace = revealWorkspace
        self.revealDocument = revealDocument; self.reportError = reportError
        self.mediaReplaceRequests = mediaReplaceRequests
    }
}

/// Read availability inside the consumer's Observation scope; dispatch resolves
/// the command again against the currently active project.
@MainActor package struct FeatureCommandContribution {
    package let id: String
    package let title: () -> String
    package let isEnabled: () -> Bool
    private let run: (FeatureCommandInvocation) -> Void
    package let requiresSelectedEditor: Bool
    package let requiresVisibleEditor: Bool
    package let revealsEditor: Bool
    package let shortcut: KeyboardShortcut?
    package let menuGroup: Int
    package let role: FeatureCommandRole?
    package let showsInMenu: Bool
    package let requiresFolderProject: Bool

    package init(id: String, title: @escaping () -> String, isEnabled: @escaping () -> Bool = { true },
                 requiresSelectedEditor: Bool = false, requiresVisibleEditor: Bool = true,
                 revealsEditor: Bool = false, shortcut: KeyboardShortcut? = nil, menuGroup: Int = 0, role: FeatureCommandRole? = nil, showsInMenu: Bool = true, requiresFolderProject: Bool = false,
                 perform: @escaping () -> Void) {
        self.init(id: id, title: title, isEnabled: isEnabled, requiresSelectedEditor: requiresSelectedEditor,
            requiresVisibleEditor: requiresVisibleEditor, revealsEditor: revealsEditor, shortcut: shortcut,
            menuGroup: menuGroup, role: role, showsInMenu: showsInMenu, requiresFolderProject: requiresFolderProject, action: { _ in perform() })
    }
    package init(id: String, title: @escaping () -> String, isEnabled: @escaping () -> Bool = { true },
                 requiresSelectedEditor: Bool = false, requiresVisibleEditor: Bool = true,
                 revealsEditor: Bool = false, shortcut: KeyboardShortcut? = nil, menuGroup: Int = 0, role: FeatureCommandRole? = nil, showsInMenu: Bool = true, requiresFolderProject: Bool = false,
                 action: @escaping (FeatureCommandInvocation) -> Void) {
        self.id = id; self.title = title; self.isEnabled = isEnabled; self.run = action
        self.requiresSelectedEditor = requiresSelectedEditor; self.requiresVisibleEditor = requiresVisibleEditor
        self.revealsEditor = revealsEditor; self.shortcut = shortcut; self.menuGroup = menuGroup; self.role = role; self.showsInMenu = showsInMenu; self.requiresFolderProject = requiresFolderProject
    }
    package func perform(_ invocation: FeatureCommandInvocation = FeatureCommandInvocation()) { run(invocation) }
}

@MainActor package struct FeatureViewContribution {
    package let makeView: (EditorRequest) -> AnyView?
    package init(makeView: @escaping (EditorRequest) -> AnyView?) { self.makeView = makeView }
}

@MainActor package struct FeatureSettingsContribution {
    package let id: String
    package let sectionID: String
    package let title: String
    package let icon: String
    package let slot: String
    package let makeView: () -> AnyView
    package init(id: String, sectionID: String, title: String, icon: String, slot: String = "page", makeView: @escaping () -> AnyView) {
        self.id = id; self.sectionID = sectionID; self.title = title; self.icon = icon; self.slot = slot; self.makeView = makeView
    }
}

@MainActor package struct FeatureBreadcrumbContribution {
    package let accessory: FeatureViewContribution?
    package let detail: (EditorRequest) -> String?
    package init(accessory: FeatureViewContribution? = nil, detail: @escaping (EditorRequest) -> String? = { _ in nil }) {
        self.accessory = accessory; self.detail = detail
    }
}

package struct FeatureActivity: Equatable, Sendable {
    package let text: String
    package let priority: Int
    package init(text: String, priority: Int = 0) { self.text = text; self.priority = priority }
}

/// Compatibility roles for existing counters; new attention kinds need no role.
package enum FeatureAttentionRole: Sendable { case runningProcesses, conversion }

package struct FeatureAttentionItem: Equatable, Sendable, Identifiable {
    package let id: String
    package let label: String
    package let detail: String
    package let symbol: String
    package let priority: Int
    package let role: FeatureAttentionRole?
    package let count: Int?
    package init(id: String, label: String, detail: String, symbol: String, priority: Int, role: FeatureAttentionRole? = nil, count: Int? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
        self.symbol = symbol
        self.priority = priority
        self.role = role; self.count = count
    }
}

/// Text around the editor transport. Read on demand alongside the owning
/// document; the host does not interpret document states or encodings.
package struct FeatureStatusSummary: Equatable, Sendable {
    package let detail: String
    package let trailing: String
    package let summarizesFileTab: Bool
    package init(detail: String, trailing: String, summarizesFileTab: Bool = true) {
        self.detail = detail
        self.trailing = trailing
        self.summarizesFileTab = summarizesFileTab
    }
}

package struct FeatureAssetTabClose {
    package let id: String
    package let kind: AssetKind
    package let url: URL?
    package init(id: String, kind: AssetKind, url: URL?) { self.id = id; self.kind = kind; self.url = url }
}

/// Optional lifecycle participation is separate from document save/close.
/// Editor visibility is emitted by the retained project host's one signal.
@MainActor package struct FeatureLifecycle {
    package var editorVisibilityChanged: ((Bool) -> Void)?
    package var projectRecovered: (() -> Void)?
    package var visibilityPriority: Int = 0
    package var willShutdown: (() -> Void)?
    package var assetChangePriority: Int = 0
    package var shutdownPriority: Int = 0
    package var assetsChanged: (([ProjectAsset]) -> Void)?
    package var refreshBackgroundState: (() -> Void)?
    package var activate: (() -> Void)?
    package var deactivate: (() -> Void)?
    package var invalidate: (() -> Void)?
    package var closeAssetTab: ((FeatureAssetTabClose) -> Bool)?
    package var assetTabClosed: ((URL) -> Void)?
    package var projectCloseWarning: (() -> String?)?
    package var confirmProjectClose: (() -> Bool)?
    package var shutdown: (() -> Void)?

    package init(editorVisibilityChanged: ((Bool) -> Void)? = nil, projectRecovered: (() -> Void)? = nil,
                 assetsChanged: (([ProjectAsset]) -> Void)? = nil, refreshBackgroundState: (() -> Void)? = nil,
                 activate: (() -> Void)? = nil, deactivate: (() -> Void)? = nil, invalidate: (() -> Void)? = nil,
                 assetTabClosed: ((URL) -> Void)? = nil, confirmProjectClose: (() -> Bool)? = nil,
                 shutdown: (() -> Void)? = nil) {
        self.editorVisibilityChanged = editorVisibilityChanged
        self.projectRecovered = projectRecovered
        self.assetsChanged = assetsChanged
        self.refreshBackgroundState = refreshBackgroundState
        self.activate = activate
        self.deactivate = deactivate
        self.invalidate = invalidate
        self.assetTabClosed = assetTabClosed
        self.confirmProjectClose = confirmProjectClose
        self.shutdown = shutdown
    }
}

/// A project retains these objects for its whole lifetime. Concrete session
/// types own their models; the host sees only declared capabilities. Features
/// receive scoped services, never this registry or a sibling session.
@MainActor package protocol ProjectFeatureSession: AnyObject {
    var featureID: FeatureID { get }
    func attachDocumentHost(_ services: DocumentHostServices)
    var documentWorkspace: DocumentWorkspaceAdapter? { get }
    var editors: [FeatureEditorContribution] { get }
    var commands: [FeatureCommandContribution] { get }
    var menus: [FeatureMenuContribution] { get }
    var settings: [FeatureSettingsContribution] { get }
    var inspector: FeatureViewContribution? { get }
    var breadcrumb: FeatureBreadcrumbContribution? { get }
    var statusSummary: FeatureStatusSummary? { get }
    var transport: FeatureViewContribution? { get }
    var attention: [FeatureAttentionItem] { get }
    var activity: FeatureActivity? { get }
    var lifecycle: FeatureLifecycle { get }
}

extension ProjectFeatureSession {
    package func attachDocumentHost(_ services: DocumentHostServices) {}
    package var documentWorkspace: DocumentWorkspaceAdapter? { nil }
    package var editors: [FeatureEditorContribution] { [] }
    package var commands: [FeatureCommandContribution] { [] }
    package var menus: [FeatureMenuContribution] { [] }
    package var settings: [FeatureSettingsContribution] { [] }
    package var inspector: FeatureViewContribution? { nil }
    package var breadcrumb: FeatureBreadcrumbContribution? { nil }
    package var statusSummary: FeatureStatusSummary? { nil }
    package var transport: FeatureViewContribution? { nil }
    package var attention: [FeatureAttentionItem] { [] }
    package var activity: FeatureActivity? { nil }
    package var lifecycle: FeatureLifecycle { FeatureLifecycle() }
}
