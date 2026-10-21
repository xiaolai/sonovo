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
                if state.needsReviewCount > 0 {
                    Text("\(state.needsReviewCount) need review")
                        .font(.system(size: AppTheme.TypeScale.xs, weight: .medium))
                        .foregroundStyle(AppTheme.Palette.needsReview)
                }
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
        let status = state.status(for: asset)
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: asset.kind.icon)
                .font(.system(size: AppTheme.TypeScale.body))
                .foregroundStyle(.secondary)
                .frame(width: AppTheme.IconSize.row)

            Text(asset.name)
                .font(.system(size: AppTheme.TypeScale.body))
                .lineLimit(1)

            Spacer(minLength: AppTheme.Spacing.xs)

            Image(systemName: status.symbol)
                .font(.system(size: AppTheme.TypeScale.xxs, weight: .semibold))
                .foregroundStyle(status.color)
                .help(status.label)
                .accessibilityLabel(status.label)
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
            Button(status == .approved ? "Reopen Review" : "Approve") {
                if status == .approved {
                    state.reopen(asset)
                } else {
                    state.approve(asset)
                }
            }
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

    var body: some View {
        if state.liveProject.isDemo {
            List(SampleContent.fileTree, children: \.children) { node in
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: node.icon)
                        .font(.system(size: AppTheme.TypeScale.body))
                        .foregroundStyle(.secondary)
                        .frame(width: AppTheme.IconSize.row)

                    Text(node.name)
                        .font(.system(size: AppTheme.TypeScale.body))
                        .lineLimit(1)

                    Spacer(minLength: AppTheme.Spacing.xs)

                    if let assetID = node.assetID,
                       let asset = state.production.asset(id: assetID) {
                        Image(systemName: state.status(for: asset).symbol)
                            .font(.system(size: AppTheme.TypeScale.xxs, weight: .semibold))
                            .foregroundStyle(state.status(for: asset).color)
                            .help(state.status(for: asset).label)
                            .accessibilityLabel(state.status(for: asset).label)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if let assetID = node.assetID {
                        state.openAsset(assetID)
                    }
                }
                .help(node.assetID == nil ? node.name : "Open \(node.name)")
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
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
}
