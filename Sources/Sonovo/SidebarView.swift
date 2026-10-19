import AppKit
import SwiftUI

struct SidebarView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            switch state.navigatorMode {
            case .production:
                ProductionListView(state: state)
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
                List(selection: Binding(
                    get: { state.selectedAssetID },
                    set: { state.openAsset($0) }
                )) {
                    ForEach(state.filteredStages) { stage in
                        Section {
                            ForEach(stage.assets) { asset in
                                AssetRow(state: state, asset: asset)
                                    .tag(asset.id)
                            }
                        } header: {
                            HStack(spacing: AppTheme.Spacing.xs) {
                                Text(stage.title.uppercased())
                                    .font(.system(size: AppTheme.TypeScale.xxs, weight: .semibold))
                                    .tracking(AppTheme.Tracking.normal)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Text("\(stage.assets.count)")
                                    .font(.system(size: AppTheme.TypeScale.xxs, design: .monospaced))
                                    .foregroundStyle(.quaternary)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .searchable(text: $state.filterText, placement: .sidebar, prompt: "Filter assets")
            }
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

private struct FileTreeView: View {
    @Bindable var state: AppState

    var body: some View {
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
    }
}
