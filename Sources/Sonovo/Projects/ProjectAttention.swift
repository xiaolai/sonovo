import Foundation

/// Why a project wants attention. Flags are stable bits; presentation order
/// is carried by `ProjectAttentionSnapshot.statuses`.
struct ProjectAttention: OptionSet, Hashable, Sendable {
    let rawValue: UInt

    static let pendingSaveDecision = ProjectAttention(rawValue: 1 << 0)
    static let offline = ProjectAttention(rawValue: 1 << 1)
    static let dirtyDocuments = ProjectAttention(rawValue: 1 << 2)
    static let runningTerminal = ProjectAttention(rawValue: 1 << 3)
    static let converting3D = ProjectAttention(rawValue: 1 << 4)
    static let backgroundChanges = ProjectAttention(rawValue: 1 << 5)
}

enum ProjectAttentionStatus: Int, CaseIterable, Identifiable, Sendable {
    case pendingSaveDecision
    case offline
    case dirtyDocuments
    case runningTerminal
    case converting3D
    case backgroundChanges

    var id: Int { rawValue }

    var flag: ProjectAttention {
        switch self {
        case .pendingSaveDecision: .pendingSaveDecision
        case .offline: .offline
        case .dirtyDocuments: .dirtyDocuments
        case .runningTerminal: .runningTerminal
        case .converting3D: .converting3D
        case .backgroundChanges: .backgroundChanges
        }
    }

    /// Short label for a menu row or accessibility value.
    var label: String {
        switch self {
        case .pendingSaveDecision: "Save decision"
        case .offline: "Unavailable"
        case .dirtyDocuments: "Unsaved"
        case .runningTerminal: "Terminal"
        case .converting3D: "Converting"
        case .backgroundChanges: "Changed on disk"
        }
    }

    var symbol: String {
        switch self {
        case .pendingSaveDecision: "questionmark.circle.fill"
        case .offline: "externaldrive.badge.xmark"
        case .dirtyDocuments: "circle.fill"
        case .runningTerminal: "terminal.fill"
        case .converting3D: "cube.transparent"
        case .backgroundChanges: "arrow.triangle.2.circlepath"
        }
    }
}

struct ProjectAttentionInput: Equatable, Sendable {
    var isOffline = false
    var dirtyDocumentCount = 0
    var hasPendingSaveDecision = false
    var runningTerminalCount = 0
    var hasRunningConversion = false
    var hasBackgroundChanges = false

    var snapshot: ProjectAttentionSnapshot {
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

struct ProjectAttentionSnapshot: Equatable, Sendable {
    let flags: ProjectAttention
    let dirtyDocumentCount: Int
    let runningTerminalCount: Int
    /// Ordered by priority; the dirty flag is omitted when a pending save
    /// decision already represents it.
    let statuses: [ProjectAttentionStatus]
    /// One sentence per status, in the same order.
    let details: [String]

    var isQuiet: Bool { statuses.isEmpty }

    var summary: String {
        details.joined(separator: " · ")
    }

    /// Chips show the first three statuses; the overview lists all.
    func badges(limit: Int = 3) -> [ProjectAttentionStatus] {
        Array(statuses.prefix(limit))
    }

    var overflowCount: Int {
        max(0, statuses.count - 3)
    }
}

extension Project {
    /// Reads observable project state directly so a chip or overview body
    /// registers the dependencies it needs. No timer-driven global cache.
    var attentionInput: ProjectAttentionInput {
        ProjectAttentionInput(
            isOffline: isOffline,
            dirtyDocumentCount: markdown.documents.filter(\.isDirty).count
                + subtitles.documents.filter(\.isDirty).count,
            hasPendingSaveDecision: markdown.pendingClose != nil,
            runningTerminalCount: terminalSessions.runningProcessCount,
            hasRunningConversion: models.hasRunningConversion,
            hasBackgroundChanges: hasActivity
        )
    }

    var attention: ProjectAttentionSnapshot {
        attentionInput.snapshot
    }
}
