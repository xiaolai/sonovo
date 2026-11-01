import SonovoFeatureAPI
import Foundation

/// Why a project wants attention. Flags are stable bits; presentation order
/// is carried by `ProjectAttentionSnapshot.statuses`.
package struct ProjectAttention: OptionSet, Hashable, Sendable {
    package init(rawValue: UInt) { self.rawValue = rawValue }
    package let rawValue: UInt

    package static let pendingSaveDecision = ProjectAttention(rawValue: 1 << 0)
    package static let offline = ProjectAttention(rawValue: 1 << 1)
    package static let dirtyDocuments = ProjectAttention(rawValue: 1 << 2)
    package static let runningTerminal = ProjectAttention(rawValue: 1 << 3)
    package static let converting3D = ProjectAttention(rawValue: 1 << 4)
    package static let backgroundChanges = ProjectAttention(rawValue: 1 << 5)
}

package enum ProjectAttentionStatus: Equatable, CaseIterable, Identifiable, Sendable {
    case pendingSaveDecision
    case offline
    case dirtyDocuments
    case runningTerminal
    case converting3D
    case backgroundChanges

    case feature(FeatureAttentionItem)
    package static let allCases: [ProjectAttentionStatus] = [.pendingSaveDecision, .offline, .dirtyDocuments, .runningTerminal, .converting3D, .backgroundChanges]
    package var priority: Int {
        switch self {
        case .pendingSaveDecision: 0
        case .offline: 1
        case .dirtyDocuments: 2
        case .runningTerminal: 3
        case .converting3D: 4
        case .backgroundChanges: 5
        case .feature(let item): item.priority
        }
    }
    package var id: String {
        if case .feature(let item) = self { return item.id }
        return "host.\(priority)"
    }

    package var flag: ProjectAttention {
        switch self {
        case .pendingSaveDecision: .pendingSaveDecision
        case .offline: .offline
        case .dirtyDocuments: .dirtyDocuments
        case .runningTerminal: .runningTerminal
        case .converting3D: .converting3D
        case .backgroundChanges: .backgroundChanges
        case .feature: []
        }
    }

    /// Short label for a menu row or accessibility value.
    package var label: String {
        switch self {
        case .pendingSaveDecision: "Save decision"
        case .offline: "Unavailable"
        case .dirtyDocuments: "Unsaved"
        case .runningTerminal: "Terminal"
        case .converting3D: "Converting"
        case .backgroundChanges: "Changed on disk"
        case .feature(let item): item.label
        }
    }

    package var symbol: String {
        switch self {
        case .pendingSaveDecision: "questionmark.circle.fill"
        case .offline: "externaldrive.badge.xmark"
        case .dirtyDocuments: "circle.fill"
        case .runningTerminal: "terminal.fill"
        case .converting3D: "cube.transparent"
        case .backgroundChanges: "arrow.triangle.2.circlepath"
        case .feature(let item): item.symbol
        }
    }
}

package struct ProjectAttentionInput: Equatable, Sendable {
    package init(isOffline: Bool = false, dirtyDocumentCount: Int = 0, hasPendingSaveDecision: Bool = false,
         runningTerminalCount: Int = 0, hasRunningConversion: Bool = false, hasBackgroundChanges: Bool = false) {
        self.isOffline = isOffline; self.dirtyDocumentCount = dirtyDocumentCount; self.hasPendingSaveDecision = hasPendingSaveDecision
        self.runningTerminalCount = runningTerminalCount; self.hasRunningConversion = hasRunningConversion
        self.hasBackgroundChanges = hasBackgroundChanges
    }
    package var isOffline = false
    package var dirtyDocumentCount = 0
    package var hasPendingSaveDecision = false
    package var runningTerminalCount = 0
    package var hasRunningConversion = false
    package var hasBackgroundChanges = false

    package var snapshot: ProjectAttentionSnapshot {
        var flags: ProjectAttention = []
        var statuses: [ProjectAttentionStatus] = []
        var details: [String] = []

        if hasPendingSaveDecision {
            flags.insert(.pendingSaveDecision)
            statuses.append(.pendingSaveDecision)
            details.append("An unsaved document needs a save decision")
        }
        if isOffline {
            flags.insert(.offline)
            statuses.append(.offline)
            details.append("Project folder is unavailable")
        }
        // The pending decision is the same underlying unsaved state; showing
        // a second dirty badge would double-count one problem.
        if dirtyDocumentCount > 0, !hasPendingSaveDecision {
            flags.insert(.dirtyDocuments)
            statuses.append(.dirtyDocuments)
            details.append(
                "\(dirtyDocumentCount) unsaved document"
                    + (dirtyDocumentCount == 1 ? "" : "s")
            )
        }
        if runningTerminalCount > 0 {
            flags.insert(.runningTerminal)
            statuses.append(.runningTerminal)
            details.append(
                "\(runningTerminalCount) terminal process"
                    + (runningTerminalCount == 1 ? "" : "es")
                    + " running"
            )
        }
        if hasRunningConversion {
            flags.insert(.converting3D)
            statuses.append(.converting3D)
            details.append("A 3D conversion is running")
        }
        if hasBackgroundChanges {
            flags.insert(.backgroundChanges)
            statuses.append(.backgroundChanges)
            details.append("Files changed on disk")
        }

        return ProjectAttentionSnapshot(
            flags: flags,
            dirtyDocumentCount: dirtyDocumentCount,
            runningTerminalCount: runningTerminalCount,
            statuses: statuses,
            details: details
        )
    }
}

package struct ProjectAttentionSnapshot: Equatable, Sendable {
    package init(flags: ProjectAttention, dirtyDocumentCount: Int, runningTerminalCount: Int,
         statuses: [ProjectAttentionStatus], details: [String]) {
        self.flags = flags; self.dirtyDocumentCount = dirtyDocumentCount; self.runningTerminalCount = runningTerminalCount
        self.statuses = statuses; self.details = details
    }
    package func adding(_ items: [FeatureAttentionItem]) -> ProjectAttentionSnapshot {
        let merged = (Array(zip(statuses, details)) + items.map { (ProjectAttentionStatus.feature($0), $0.detail) })
            .sorted { ($0.0.priority, $0.0.id) < ($1.0.priority, $1.0.id) }
        return ProjectAttentionSnapshot(flags: flags, dirtyDocumentCount: dirtyDocumentCount, runningTerminalCount: runningTerminalCount,
            statuses: merged.map { $0.0 }, details: merged.map { $0.1 })
    }
    package let flags: ProjectAttention
    package let dirtyDocumentCount: Int
    package let runningTerminalCount: Int
    /// Ordered by priority; the dirty flag is omitted when a pending save
    /// decision already represents it.
    package let statuses: [ProjectAttentionStatus]
    /// One sentence per status, in the same order.
    package let details: [String]

    package var isQuiet: Bool { statuses.isEmpty }

    package var summary: String {
        details.joined(separator: " · ")
    }

    /// Chips show the first three statuses; the overview lists all.
    package func badges(limit: Int = 3) -> [ProjectAttentionStatus] {
        Array(statuses.prefix(limit))
    }

    package var overflowCount: Int {
        max(0, statuses.count - 3)
    }
}

extension Project {
    /// Reads observable project state directly so a chip or overview body
    /// registers the dependencies it needs. No timer-driven global cache.
    package var attentionInput: ProjectAttentionInput {
        ProjectAttentionInput(
            isOffline: isOffline,
            dirtyDocumentCount: documentWorkspaces.dirtyAttentionCount,
            hasPendingSaveDecision: documentWorkspaces.hasPendingDecision,
            runningTerminalCount: featureSessions.attention.filter { $0.role == .runningProcesses }.reduce(0) { $0 + ($1.count ?? 0) },
            hasRunningConversion: featureSessions.attention.contains { $0.role == .conversion },
            hasBackgroundChanges: hasActivity
        )
    }

    package var attention: ProjectAttentionSnapshot {
        attentionInput.snapshot.adding(featureSessions.attention.filter { $0.role == nil })
    }
}
