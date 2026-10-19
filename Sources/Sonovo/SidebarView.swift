import AppKit
import SwiftUI

struct SidebarView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            switch state.navigatorMode {
            case .production:
                ProductionListView(state: state)
            case .files:
                FileTreeView(state: state)
            }
            SidebarFooter(state: state)
        }
    }
}

private struct ProductionListView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("PRODUCTION")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                Spacer()
                if state.needsReviewCount > 0 {
                    Text("\(state.needsReviewCount) need review")
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        .foregroundStyle(.orange)
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
                                    .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                                    .tracking(0.7)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Text("\(stage.assets.count)")
                                    .font(.system(size: AppTheme.FontSize.xxs, design: .monospaced))
                                    .foregroundStyle(.quaternary)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
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
                .font(.system(size: AppTheme.FontSize.body))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(asset.name)
                .font(.system(size: AppTheme.FontSize.body))
                .lineLimit(1)

            Spacer(minLength: AppTheme.Spacing.xs)

            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
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
                    .font(.system(size: AppTheme.FontSize.body))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Text(node.name)
                    .font(.system(size: AppTheme.FontSize.body))
                    .lineLimit(1)

                Spacer(minLength: AppTheme.Spacing.xs)

                if let assetID = node.assetID,
                   let asset = state.production.asset(id: assetID) {
                    Circle()
                        .fill(state.status(for: asset).color)
                        .frame(width: 5, height: 5)
                        .help(state.status(for: asset).label)
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

private struct SidebarFooter: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Menu {
                Button("Request New Take") {
                    state.newTake()
                }
                Button("New Note") {
                    state.inspectorVisible = true
                    state.inspectorTab = .notes
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("New")

            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(.secondary)

                TextField("Filter", text: $state.filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm))

                if !state.filterText.isEmpty {
                    Button {
                        state.filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                }
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
            )
            .disabled(state.navigatorMode == .files)
            .opacity(state.navigatorMode == .files ? 0.55 : 1)
            .help(state.navigatorMode == .files ? "Filter is available in Production" : "Filter assets")
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.appSeparator)
                .frame(height: AppTheme.BorderWidth.hairline)
        }
    }
}
