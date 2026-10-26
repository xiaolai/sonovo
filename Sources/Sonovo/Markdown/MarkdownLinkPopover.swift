import AppKit
import SonovoCore
import SwiftUI

/// Hosts the link popover and keeps its target captured at presentation.
@MainActor
final class MarkdownLinkPopoverController {
    private let popover = NSPopover()

    func show(
        target: MarkdownLinkTarget,
        headings: [HeadingEntry],
        relativeTo rect: NSRect,
        of view: NSView,
        onCommit: @escaping (MarkdownLinkValues) -> Void,
        onRemove: @escaping () -> Void,
        onCopy: @escaping (String) -> Void,
        onOpen: @escaping (String) -> Void,
        onOpenWiki: @escaping (WikiLink) -> Void,
        onOpenDefinition: @escaping () -> Void
    ) {
        popover.behavior = .transient
        let root = MarkdownLinkPopoverView(
            target: target,
            headings: headings,
            onCommit: onCommit,
            onRemove: onRemove,
            onCopy: onCopy,
            onOpen: onOpen,
            onOpenWiki: onOpenWiki,
            onOpenDefinition: onOpenDefinition,
            onCancel: { [weak self] in self?.close() }
        )
        popover.contentViewController = NSHostingController(rootView: root)
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    func close() {
        popover.performClose(nil)
    }
}

private struct MarkdownLinkPopoverView: View {
    let target: MarkdownLinkTarget
    let headings: [HeadingEntry]
    let onCommit: (MarkdownLinkValues) -> Void
    let onRemove: () -> Void
    let onCopy: (String) -> Void
    let onOpen: (String) -> Void
    let onOpenWiki: (WikiLink) -> Void
    let onOpenDefinition: () -> Void
    let onCancel: () -> Void

    @State private var values: MarkdownLinkValues

    init(
        target: MarkdownLinkTarget,
        headings: [HeadingEntry],
        onCommit: @escaping (MarkdownLinkValues) -> Void,
        onRemove: @escaping () -> Void,
        onCopy: @escaping (String) -> Void,
        onOpen: @escaping (String) -> Void,
        onOpenWiki: @escaping (WikiLink) -> Void,
        onOpenDefinition: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.target = target
        self.headings = headings
        self.onCommit = onCommit
        self.onRemove = onRemove
        self.onCopy = onCopy
        self.onOpen = onOpen
        self.onOpenWiki = onOpenWiki
        self.onOpenDefinition = onOpenDefinition
        self.onCancel = onCancel
        _values = State(
            initialValue: MarkdownLinkValues(
                text: target.text,
                destination: target.destination,
                title: target.title,
                target: target.label,
                alias: target.alias
            )
        )
    }

    private var title: String {
        switch target.kind {
        case .link: return "Link"
        case .image: return "Image"
        case .wikiLink: return "Wiki Link"
        }
    }

    private var targetBinding: Binding<String> {
        Binding(
            get: { values.target ?? "" },
            set: { values.target = $0 }
        )
    }

    private var aliasBinding: Binding<String> {
        Binding(
            get: { values.alias ?? "" },
            set: { values.alias = $0 }
        )
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { values.title ?? "" },
            set: { values.title = $0.isEmpty ? nil : $0 }
        )
    }

    private struct HeadingChoice: Identifiable {
        let id: Int
        let text: String
        let slug: String
    }

    private var headingChoices: [HeadingChoice] {
        var choices: [HeadingChoice] = []
        for entry in headings {
            guard let slug = entry.slug else { continue }
            choices.append(
                HeadingChoice(
                    id: choices.count,
                    text: entry.text,
                    slug: slug
                )
            )
        }
        return choices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            header
            fields
            actions
            footer
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: AppTheme.TypeScale.sm))
        .padding(AppTheme.MarkdownChrome.Popover.padding)
        .frame(width: AppTheme.MarkdownChrome.Popover.width)
        .background(AppTheme.MarkdownChrome.Popover.background)
    }

    private var header: some View {
        HStack {
            Text(title)
                .font(
                    .system(
                        size: AppTheme.TypeScale.sm,
                        weight: .semibold
                    )
                )
            Spacer()
            if !target.isEditable {
                Text("Read-only in v1")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var fields: some View {
        if target.kind == .wikiLink {
            TextField("Target", text: targetBinding)
            TextField("Alias", text: aliasBinding)
        } else {
            TextField("Text", text: $values.text)
            TextField("Destination", text: $values.destination)
                .accessibilityHint(
                    "A web address, a path inside the workspace, or an anchor"
                )
            TextField("Title", text: titleBinding)
            if !headingChoices.isEmpty {
                headingPicker
            }
        }
    }

    private var headingPicker: some View {
        Menu("Pick Heading") {
            ForEach(headingChoices) { choice in
                Button(choice.text) {
                    values.destination = "#" + choice.slug
                }
            }
        }
        .accessibilityLabel("Pick a heading")
    }

    private var actions: some View {
        HStack {
            Button("Remove", role: .destructive, action: onRemove)
                .disabled(!target.isEditable)
            if target.definitionRange != nil {
                Button("Open Definition", action: onOpenDefinition)
            }
            Spacer()
            Button("Copy") { onCopy(actionDestination) }
            Button("Open") {
                if target.kind == .wikiLink {
                    onOpenWiki(editedWikiLink)
                } else {
                    onOpen(actionDestination)
                }
            }
            // A wiki link's value lives in the Target field, not in
            // `destination`, which is only the target as it was presented.
            .disabled(actionDestination.isEmpty)
        }
    }

    private var actionDestination: String {
        target.kind == .wikiLink
            ? (values.target ?? target.destination)
            : values.destination
    }

    /// The edited wiki target split into its path and `#fragment` parts, so
    /// Open goes through the same resolver as a wiki link in the reader.
    private var editedWikiLink: WikiLink {
        let raw = actionDestination.trimmingCharacters(in: .whitespaces)
        let parts = raw.split(
            separator: "#",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let name = String(parts.first ?? "")
        let fragment = parts.count > 1 ? String(parts[1]) : ""
        let alias = (values.alias ?? "").trimmingCharacters(in: .whitespaces)
        return WikiLink(
            target: name,
            fragment: fragment.isEmpty ? nil : fragment,
            alias: alias.isEmpty ? nil : alias
        )
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
            Button("Apply") { onCommit(values) }
                .keyboardShortcut(.defaultAction)
                .disabled(!target.isEditable)
        }
    }
}
