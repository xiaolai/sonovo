import AppKit
import SwiftUI

struct SidebarView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            HStack(spacing: AppTheme.Spacing.s6) {
                NavigatorModeTabs(state: state)
                SidebarFilterField(state: state)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.top, AppTheme.Spacing.sm)
            .padding(.bottom, AppTheme.Spacing.sm)

            if let error = state.workspace.lastError {
                Text(error)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(AppTheme.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.bottom, AppTheme.Spacing.xs)
                    .onTapGesture {
                        state.workspace.lastError = nil
                    }
            }

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

/// The navigator's filter. It sits below the tabs and above the content, so
/// the same field filters Production assets and the file tree in Files.
private struct SidebarFilterField: View {
    @Bindable var state: AppState
    @FocusState private var focused: Bool

    private var prompt: String {
        state.navigatorMode == .files ? "Filter files" : "Filter assets"
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.s6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.tertiary)

            TextField(prompt, text: $state.filterText)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.TypeScale.body))
                .focused($focused)
                .accessibilityLabel(prompt)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !state.filterText.isEmpty {
                Button {
                    state.filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: AppTheme.TypeScale.sm))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: AppTheme.ControlSize.medium)
        .layoutPriority(1)
        .background(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.control,
                style: .continuous
            )
            .fill(Color.appCard)
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.control,
                style: .continuous
            )
            .strokeBorder(
                Color.appSeparator,
                lineWidth: AppTheme.BorderWidth.hairline
            )
        )
        .onChange(of: state.focusSidebarFilter) { _, _ in
            focused = true
        }
        .onExitCommand {
            if state.filterText.isEmpty {
                focused = false
            } else {
                state.filterText = ""
            }
        }
    }
}

private struct NavigatorModeTabs: View {
    @Bindable var state: AppState

    var body: some View {
        Picker("Navigator", selection: $state.navigatorMode) {
            ForEach(NavigatorMode.allCases) { mode in
                Image(systemName: mode.icon)
                    .accessibilityLabel(mode.label)
                    .help(mode.label)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel("Navigator")
        .fixedSize()
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

    private var project: Project { state.liveProject }

    private var nodes: [FileNode] {
        project.isDemo ? SampleContent.fileTree : project.fileTree
    }

    private var visibleNodes: [FileNode] {
        FileNode.filtered(nodes, query: state.filterText)
    }

    private var isFiltering: Bool {
        !project.trimmedFilterText.isEmpty
    }

    var body: some View {
        if case .offline(let reason) = project.availability {
            ContentUnavailableView(
                "Project Offline",
                systemImage: "externaldrive.badge.xmark",
                description: Text(reason)
            )
            .frame(maxHeight: .infinity)
        } else if project.assets.isEmpty,
                  !project.isDemo,
                  project.availability == .scanning {
            ProgressView("Scanning…")
                .frame(maxHeight: .infinity)
        } else if visibleNodes.isEmpty {
            ContentUnavailableView(
                isFiltering ? "No Matches" : "Empty Project",
                systemImage: isFiltering ? "magnifyingglass" : "folder",
                description: Text(
                    isFiltering
                        ? "No files match “\(state.filterText)”."
                        : "No readable files were found in this folder."
                )
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                        ForEach(visibleNodes) { node in
                            FileTreeNodeRow(
                                state: state,
                                node: node,
                                level: 0,
                                expanded: $expanded,
                                forceExpanded: isFiltering
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
            .onChange(of: project.id) { _, _ in
                expanded.removeAll()
            }
        }
    }

    /// "Show in Files" must reveal a node inside a collapsed folder, then
    /// scroll to it once the expansion renders.
    private func reveal(_ assetID: String?, proxy: ScrollViewProxy) {
        guard let assetID,
              let nodeID = Self.nodeID(forAsset: assetID, in: nodes) else {
            return
        }
        if let ancestors = Self.ancestors(ofAsset: assetID, in: nodes) {
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
    /// A filtered tree shows matching structure without requiring the user to
    /// expand every ancestor by hand.
    let forceExpanded: Bool

    private var isSelected: Bool {
        node.assetID != nil && node.assetID == state.selectedAssetID
    }

    private var isExpanded: Bool {
        forceExpanded || expanded.contains(node.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            HStack(spacing: AppTheme.Spacing.sm) {
                if node.children != nil {
                    Image(
                        systemName: isExpanded
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

            if isExpanded, let children = node.children {
                ForEach(children) { child in
                    FileTreeNodeRow(
                        state: state,
                        node: child,
                        level: level + 1,
                        expanded: $expanded,
                        forceExpanded: forceExpanded
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
