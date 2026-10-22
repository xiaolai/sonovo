import AppKit
import SwiftUI

struct SidebarView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            ProjectSwitcherView(state: state)
            switch state.navigatorMode {
            case .production:
                if state.liveProject.isDemo {
                    ProductionListView(state: state)
                } else {
                    ProjectAssetListView(state: state)
                }
            case .files:
                FileTreeView(state: state)
            }
        }
        .background(Color.appText)
    }
}

private struct ProductionListView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            HStack(spacing: AppTheme.Spacing.s6) {
                Text("PRODUCTION")
                    .font(.system(size: AppTheme.TypeScale.xxs, weight: .semibold))
                    .tracking(AppTheme.Tracking.wide)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.top, AppTheme.Spacing.sm)
            .padding(.bottom, AppTheme.Spacing.xs)

            if state.filteredStages.isEmpty {
                ContentUnavailableView(
                    "No Matches",
                    systemImage: "magnifyingglass",
                    description: Text("No assets match “\(state.filterText)”.")
                )
                .frame(maxHeight: .infinity)
            } else {
                SidebarGroupedList(
                    groups: state.filteredStages,
                    title: { $0.title },
                    items: { $0.assets },
                    selection: Binding(
                        get: { state.selectedAssetID },
                        set: { state.openAsset($0) }
                    ),
                    row: { asset in
                        AssetRow(state: state, asset: asset)
                    }
                )
            }
        }
        // Keep the search field outside the result branches. Attaching it to
        // the List removes the field exactly when a query returns no rows,
        // leaving the user unable to correct the query.
        .searchable(
            text: $state.filterText,
            placement: .sidebar,
            prompt: "Filter assets"
        )
    }
}

private struct SidebarGroupedList<
    Group: Identifiable,
    Item: Identifiable,
    Row: View
>: View where Item.ID == String {
    let groups: [Group]
    let title: (Group) -> String
    let items: (Group) -> [Item]
    let selection: Binding<String?>
    let row: (Item) -> Row

    var body: some View {
        List(selection: selection) {
            ForEach(groups) { group in
                Section {
                    ForEach(items(group)) { item in
                        row(item).tag(item.id)
                    }
                } header: {
                    SidebarSectionHeader(
                        title: title(group),
                        count: items(group).count
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Text(title.uppercased())
                .font(.system(size: AppTheme.TypeScale.xxs, weight: .semibold))
                .tracking(AppTheme.Tracking.normal)
                .foregroundStyle(.tertiary)
            Spacer()
            Text("\(count)")
                .font(.system(size: AppTheme.TypeScale.xxs, design: .monospaced))
                .foregroundStyle(.quaternary)
        }
    }
}

private struct AssetRow: View {
    let state: AppState
    let asset: ProductionAsset

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: asset.kind.icon)
                .font(.system(size: AppTheme.TypeScale.body))
                .foregroundStyle(.secondary)
                .frame(width: AppTheme.IconSize.row)

            Text(asset.name)
                .font(.system(size: AppTheme.TypeScale.body))
                .lineLimit(1)

            Spacer(minLength: AppTheme.Spacing.xs)
        }
        .help(asset.detail)
        .contextMenu {
            Button("Open") {
                state.openAsset(asset.id)
            }
            Button("Show in Files") {
                state.navigatorMode = .files
                state.selectedAssetID = asset.id
            }
            Divider()
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(asset.name, forType: .string)
            }
        }
    }
}

private struct ProjectAssetListView: View {
    @Bindable var state: AppState

    private var project: Project { state.liveProject }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            header

            if case .offline(let reason) = project.availability {
                offlineState(reason)
            } else if project.assets.isEmpty,
                      project.availability == .scanning {
                ProgressView("Scanning…")
                    .frame(maxHeight: .infinity)
            } else if project.filteredGroups.isEmpty {
                ContentUnavailableView(
                    project.assets.isEmpty ? "Empty Project" : "No Matches",
                    systemImage: project.assets.isEmpty
                        ? "folder"
                        : "magnifyingglass",
                    description: Text(
                        project.assets.isEmpty
                            ? "No readable files were found in this folder."
                            : "No files match “\(state.filterText)”."
                    )
                )
                .frame(maxHeight: .infinity)
            } else {
                SidebarGroupedList(
                    groups: project.filteredGroups,
                    title: { $0.title },
                    items: { $0.assets },
                    selection: Binding(
                        get: { state.selectedAssetID },
                        set: { state.openAsset($0) }
                    ),
                    row: { asset in
                        ProjectAssetRow(state: state, asset: asset)
                    }
                )

                if project.truncated {
                    Text("Showing the first 20,000 files.")
                        .font(.system(size: AppTheme.TypeScale.xxs))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.vertical, AppTheme.Spacing.xs)
                }
            }
        }
        // The field must survive an empty result set, or the user cannot
        // edit the query that produced it.
        .searchable(
            text: $state.filterText,
            placement: .sidebar,
            prompt: "Filter files"
        )
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.s6) {
            Text("PROJECT")
                .font(.system(size: AppTheme.TypeScale.xxs, weight: .semibold))
                .tracking(AppTheme.Tracking.wide)
                .foregroundStyle(.tertiary)
            Spacer()
            Text("\(project.assets.count) files")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.top, AppTheme.Spacing.sm)
        .padding(.bottom, AppTheme.Spacing.xs)
    }

    private func offlineState(_ reason: String) -> some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "externaldrive.badge.xmark")
                .font(.system(size: AppTheme.TypeScale.displayLarge, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("Project Offline")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .medium))
            Text(reason)
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                state.workspace.retry(project)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxHeight: .infinity)
    }
}

private struct ProjectAssetRow: View {
    let state: AppState
    let asset: ProjectAsset

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            ProjectAssetThumbnailView(asset: asset)

            Text(asset.name)
                .font(.system(size: AppTheme.TypeScale.body))
                .lineLimit(1)

            Spacer(minLength: AppTheme.Spacing.xs)

            Text(asset.fileExtension.uppercased())
                .font(.system(size: AppTheme.TypeScale.xxs, design: .monospaced))
                .foregroundStyle(.quaternary)
        }
        .help(asset.detail)
        .contextMenu {
            Button("Open") {
                state.liveProject.openAsset(asset)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([asset.url])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(asset.url.path, forType: .string)
            }
        }
    }
}

private struct FileTreeView: View {
    @Bindable var state: AppState
    @State private var expanded: Set<String> = []

    var body: some View {
        if state.liveProject.isDemo {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                        ForEach(SampleContent.fileTree) { node in
                            FileTreeNodeRow(
                                state: state,
                                node: node,
                                level: 0,
                                expanded: $expanded
                            )
                        }
                    }
                    .padding(.vertical, AppTheme.Spacing.xs)
                }
                .onAppear {
                    // The Files navigator can mount after "Show in Files"
                    // already set the selection; no change event follows.
                    reveal(state.selectedAssetID, proxy: proxy)
                }
                .onChange(of: state.selectedAssetID) { _, assetID in
                    reveal(assetID, proxy: proxy)
                }
            }
        } else {
            ContentUnavailableView(
                "Project Files",
                systemImage: "folder",
                description: Text(
                    "Readable files for this project are grouped in the "
                        + "Production navigator."
                )
            )
            .frame(maxHeight: .infinity)
        }
    }

    /// "Show in Files" must reveal a node inside a collapsed folder, then
    /// scroll to it once the expansion renders.
    private func reveal(_ assetID: String?, proxy: ScrollViewProxy) {
        guard let assetID,
              let nodeID = Self.nodeID(
                  forAsset: assetID,
                  in: SampleContent.fileTree
              ) else {
            return
        }
        if let ancestors = Self.ancestors(
            ofAsset: assetID,
            in: SampleContent.fileTree
        ) {
            expanded.formUnion(ancestors)
        }
        DispatchQueue.main.async {
            withAnimation {
                proxy.scrollTo(nodeID, anchor: .center)
            }
        }
    }

    private static func nodeID(
        forAsset assetID: String,
        in nodes: [FileNode]
    ) -> String? {
        for node in nodes {
            if node.assetID == assetID { return node.id }
            if let children = node.children,
               let found = nodeID(forAsset: assetID, in: children) {
                return found
            }
        }
        return nil
    }

    /// The folder IDs that contain the asset, outermost first.
    private static func ancestors(
        ofAsset assetID: String,
        in nodes: [FileNode]
    ) -> Set<String>? {
        var path: [String] = []

        func walk(_ nodes: [FileNode]) -> Bool {
            for node in nodes {
                if node.assetID == assetID { return true }
                guard let children = node.children else { continue }
                path.append(node.id)
                if walk(children) { return true }
                path.removeLast()
            }
            return false
        }

        return walk(nodes) ? Set(path) : nil
    }
}

/// One row of the demo file tree. Folders toggle; files open.
private struct FileTreeNodeRow: View {
    let state: AppState
    let node: FileNode
    let level: Int
    @Binding var expanded: Set<String>

    private var isSelected: Bool {
        node.assetID != nil && node.assetID == state.selectedAssetID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            HStack(spacing: AppTheme.Spacing.sm) {
                if node.children != nil {
                    Image(
                        systemName: expanded.contains(node.id)
                            ? "chevron.down"
                            : "chevron.right"
                    )
                    .font(
                        .system(
                            size: AppTheme.TypeScale.xxs,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(.secondary)
                    .frame(width: AppTheme.IconSize.row)
                } else {
                    Color.clear
                        .frame(width: AppTheme.IconSize.row)
                }

                Image(systemName: node.icon)
                    .font(.system(size: AppTheme.TypeScale.body))
                    .foregroundStyle(.secondary)
                    .frame(width: AppTheme.IconSize.row)

                Text(node.name)
                    .font(.system(size: AppTheme.TypeScale.body))
                    .lineLimit(1)

                Spacer(minLength: AppTheme.Spacing.xs)
            }
            .padding(.leading, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(
                    cornerRadius: AppTheme.Radius.micro,
                    style: .continuous
                )
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(AppTheme.Opacity.tint)
                        : Color.clear
                )
            )
            .padding(.leading, CGFloat(level) * AppTheme.Spacing.md)
            .onTapGesture {
                if node.children != nil {
                    toggle()
                } else if let assetID = node.assetID {
                    state.openAsset(assetID)
                }
            }
            .help(node.assetID == nil ? node.name : "Open \(node.name)")

            if expanded.contains(node.id), let children = node.children {
                ForEach(children) { child in
                    FileTreeNodeRow(
                        state: state,
                        node: child,
                        level: level + 1,
                        expanded: $expanded
                    )
                }
            }
        }
        .id(node.id)
    }

    private func toggle() {
        if expanded.contains(node.id) {
            expanded.remove(node.id)
        } else {
            expanded.insert(node.id)
        }
    }
}
