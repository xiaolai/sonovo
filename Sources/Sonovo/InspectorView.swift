import SwiftUI

enum InspectorPlacement: Equatable {
    case right
    case bottom
    case hidden
}

struct InspectorView: View {
    @Bindable var state: AppState
    var placement: InspectorPlacement = .right

    var body: some View {
        Group {
            if placement == .bottom {
                bottomBody
            } else {
                rightBody
            }
        }
    }

    private var rightBody: some View {
        VStack(spacing: 0) {
            inspectorTabs

            switch state.inspectorTab {
            case .info:
                infoContent
            case .history:
                historyContent
            case .notes:
                notesContent
            }
        }
        .background(.regularMaterial)
    }

    private var bottomBody: some View {
        VStack(spacing: 0) {
            bottomHeader
            Hairline()
            bottomContent
        }
        .background(.regularMaterial)
    }

    private var bottomHeader: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Picker("Inspector", selection: $state.inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Image(systemName: tab.icon)
                        .accessibilityLabel(tab.label)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 96)

            if let asset = state.selectedAsset {
                Text(asset.name)
                    .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                    .lineLimit(1)
                StatusBadge(status: state.status(for: asset))
                Spacer(minLength: AppTheme.Spacing.sm)
                bottomActions(for: asset)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(height: 34)
        .background(.bar)
    }

    @ViewBuilder
    private func bottomActions(for asset: ProductionAsset) -> some View {
        if state.status(for: asset) == .approved {
            Label("Approved", systemImage: "checkmark.circle.fill")
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(.green)
            Button("Reopen Review") { state.reopen(asset) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        } else {
            Button {
                state.approve(asset)
            } label: {
                Label("Approve", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button {
                state.requestChange(for: asset)
            } label: {
                Label("Request Change…", systemImage: "text.bubble")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var bottomContent: some View {
        if let asset = state.selectedAsset {
            switch state.inspectorTab {
            case .info:
                bottomInfo(asset)
            case .history:
                bottomHistory
            case .notes:
                bottomNotes
            }
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "sidebar.right",
                description: Text("Select an asset to inspect it.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func bottomInfo(_ asset: ProductionAsset) -> some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.xl) {
                bottomInfoColumn("File", rows: metadataRows(for: asset))
                bottomInfoColumn("Provenance", rows: provenanceRows(for: asset))
                bottomInfoColumn("Review", rows: [
                    MetadataItem(label: "Status", value: state.status(for: asset).label),
                    MetadataItem(label: "Open notes", value: "\(state.notes.filter { !$0.isResolved }.count)"),
                    MetadataItem(label: "Approved by", value: state.status(for: asset) == .approved ? "You" : "—")
                ])
                bottomLatestNote
            }
            .padding(AppTheme.Spacing.md)
        }
    }

    private func bottomInfoColumn(_ title: String, rows: [MetadataItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.tertiary)

            ForEach(rows) { item in
                MetadataRow(label: item.label, value: item.value)
            }
        }
        .frame(minWidth: 170, alignment: .leading)
    }

    @ViewBuilder
    private var bottomLatestNote: some View {
        if let note = state.notes.first(where: { !$0.isResolved }) {
            VStack(alignment: .leading, spacing: 5) {
                Text("LATEST NOTE")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(.tertiary)

                HStack(spacing: 5) {
                    Text(note.timecode)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Text(note.createdAt)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                Text(note.text)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .lineLimit(4)

                Button("Open Notes") {
                    state.inspectorTab = .notes
                }
                .buttonStyle(.link)
                .font(.system(size: AppTheme.FontSize.xs))
            }
            .frame(width: 260, alignment: .leading)
            .padding(AppTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .fill(Color.appCard)
            )
        }
    }

    private var bottomHistory: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                ForEach(SampleContent.takes) { take in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Text(take.name)
                                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                            if take.id == "take-03" {
                                Text("Current")
                                    .font(.system(size: 8, weight: .medium))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                    .foregroundStyle(Color.accentColor)
                            }
                            Spacer()
                            StatusBadge(status: take.status, compact: true)
                        }

                        Text(take.detail)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(.secondary)
                        Text(take.createdAt)
                            .font(.system(size: AppTheme.FontSize.xxs))
                            .foregroundStyle(.tertiary)

                        if take.status == .approved {
                            Button("Compare with Current") {
                                if state.canUseReviewModes {
                                    state.editorMode = .compare
                                }
                            }
                            .buttonStyle(.link)
                            .font(.system(size: AppTheme.FontSize.xs))
                        }
                    }
                    .padding(AppTheme.Spacing.sm)
                    .frame(width: 210, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                            .fill(Color.appCard)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                            .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
                    )
                }
            }
            .padding(AppTheme.Spacing.md)
        }
    }

    private var bottomNotes: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                    ForEach(state.notes) { note in
                        bottomNoteCard(note)
                    }
                }
                .padding(AppTheme.Spacing.md)
            }

            Hairline()

            HStack(spacing: AppTheme.Spacing.xs) {
                TextField(
                    "Add a note at \(TranscriptSegment.timecode(for: state.playhead))…",
                    text: $state.noteDraft
                )
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
                .onSubmit {
                    state.addNote()
                }

                Button {
                    state.addNote()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(
                            state.noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.secondary
                                : Color.accentColor
                        )
                }
                .buttonStyle(.plain)
                .disabled(state.noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .fill(Color.appCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
            )
            .padding(AppTheme.Spacing.sm)
        }
    }

    private func bottomNoteCard(_ note: ReviewNote) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(note.timecode)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.10)))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Button {
                    state.toggleNoteResolved(note.id)
                } label: {
                    Image(systemName: note.isResolved ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(note.isResolved ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(note.isResolved ? "Reopen note" : "Resolve note")
            }

            Text(note.text)
                .font(.system(size: AppTheme.FontSize.xs))
                .lineLimit(3)

            Text("\(note.author) · \(note.createdAt)")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(.tertiary)
        }
        .padding(AppTheme.Spacing.sm)
        .frame(width: 260, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(Color.appCard.opacity(note.isResolved ? 0.5 : 1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
        )
        .opacity(note.isResolved ? 0.65 : 1)
    }

    private var inspectorTabs: some View {
        HStack(spacing: 1) {
            ForEach(InspectorTab.allCases) { tab in
                Button {
                    state.inspectorTab = tab
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: AppTheme.FontSize.body))
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.xs, style: .continuous)
                                .fill(state.inspectorTab == tab ? Color.accentColor.opacity(0.11) : Color.clear)
                        )
                        .foregroundStyle(state.inspectorTab == tab ? Color.accentColor : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.label)
                .accessibilityLabel("\(tab.label) inspector")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Hairline()
        }
    }

    private var infoContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let asset = state.selectedAsset {
                    assetHeader(asset)

                    InspectorSection("File") {
                        ForEach(metadataRows(for: asset)) { item in
                            MetadataRow(label: item.label, value: item.value)
                        }
                    }

                    InspectorSection("Provenance") {
                        ForEach(provenanceRows(for: asset)) { item in
                            MetadataRow(label: item.label, value: item.value)
                        }
                    }

                    InspectorSection("Review") {
                        MetadataRow(label: "Status", value: state.status(for: asset).label)
                        MetadataRow(label: "Open notes", value: "\(state.notes.filter { !$0.isResolved }.count)")
                        MetadataRow(label: "Approved by", value: state.status(for: asset) == .approved ? "You" : "—")
                    }

                    latestNote

                    reviewActions(for: asset)
                } else {
                    ContentUnavailableView(
                        "No Selection",
                        systemImage: "sidebar.right",
                        description: Text("Select an asset to inspect it.")
                    )
                    .padding(.top, 40)
                }
            }
            .padding(AppTheme.Spacing.lg)
        }
    }

    private func assetHeader(_ asset: ProductionAsset) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: asset.kind.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(asset.name)
                    .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                    .lineLimit(2)

                HStack(spacing: AppTheme.Spacing.xs) {
                    StatusBadge(status: state.status(for: asset))
                    Text(asset.shortDetail)
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var latestNote: some View {
        Group {
            if let note = state.notes.first(where: { !$0.isResolved }) {
                InspectorSection("Latest Note") {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            Text(note.timecode)
                                .font(.system(size: AppTheme.FontSize.xxs, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                            Spacer()
                            Text(note.createdAt)
                                .font(.system(size: AppTheme.FontSize.xxs))
                                .foregroundStyle(.tertiary)
                        }

                        Text(note.text)
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button("Open Notes") {
                            state.inspectorTab = .notes
                        }
                        .buttonStyle(.link)
                        .font(.system(size: AppTheme.FontSize.xs))
                    }
                    .padding(AppTheme.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                            .fill(Color.appCard)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func reviewActions(for asset: ProductionAsset) -> some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Hairline()

            if state.status(for: asset) == .approved {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Approved")
                        .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    Spacer()
                }

                Button {
                    state.reopen(asset)
                } label: {
                    Text("Reopen Review")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                Button {
                    state.approve(asset)
                } label: {
                    Label("Approve", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    state.requestChange(for: asset)
                } label: {
                    Label("Request Change…", systemImage: "text.bubble")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    private var historyContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Takes")
                        .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                    Spacer()
                    Text("\(SampleContent.takes.count) versions")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, AppTheme.Spacing.lg)

                ForEach(Array(SampleContent.takes.enumerated()), id: \.element.id) { index, take in
                    HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                        VStack(spacing: 0) {
                            Circle()
                                .fill(take.status.color)
                                .frame(width: 7, height: 7)
                                .padding(.top, 5)

                            if index < SampleContent.takes.count - 1 {
                                Rectangle()
                                    .fill(Color.appSeparator)
                                    .frame(width: 1, height: 42)
                            }
                        }
                        .frame(width: 8)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: AppTheme.Spacing.xs) {
                                Text(take.name)
                                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                                if take.id == "take-03" {
                                    Text("Current")
                                        .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                        .foregroundStyle(Color.accentColor)
                                }
                                Spacer()
                                StatusBadge(status: take.status, compact: true)
                            }

                            Text(take.detail)
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(.secondary)

                            Text(take.createdAt)
                                .font(.system(size: AppTheme.FontSize.xxs))
                                .foregroundStyle(.tertiary)

                            if take.status == .approved {
                                Button("Compare with Current") {
                                    if state.canUseReviewModes {
                                        state.editorMode = .compare
                                    }
                                }
                                .buttonStyle(.link)
                                .font(.system(size: AppTheme.FontSize.xs))
                                .padding(.top, 2)
                            }
                        }
                        .padding(.bottom, AppTheme.Spacing.lg)
                    }
                }
            }
            .padding(AppTheme.Spacing.lg)
        }
    }

    private var notesContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Review Notes")
                    .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                Spacer()
                Text("\(state.notes.filter { !$0.isResolved }.count) open")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)

            Hairline()

            ScrollView {
                LazyVStack(spacing: AppTheme.Spacing.sm) {
                    ForEach(state.notes) { note in
                        NoteCard(state: state, note: note)
                    }
                }
                .padding(AppTheme.Spacing.md)
            }

            Hairline()

            noteComposer
                .padding(AppTheme.Spacing.sm)
                .background(.bar)
        }
    }

    private var noteComposer: some View {
        let timecode = TranscriptSegment.timecode(for: state.playhead)

        return HStack(spacing: AppTheme.Spacing.xs) {
            TextField("Add a note at \(timecode)…", text: $state.noteDraft)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
                .onSubmit {
                    state.addNote()
                }

            Button {
                state.addNote()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(
                        state.noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.secondary
                            : Color.accentColor
                    )
            }
            .buttonStyle(.plain)
            .disabled(state.noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Add note")
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .fill(Color.appCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
        )
    }

    private func metadataRows(for asset: ProductionAsset) -> [MetadataItem] {
        switch asset.kind {
        case .audio:
            [
                MetadataItem(label: "Kind", value: "WAV audio"),
                MetadataItem(label: "Duration", value: "00:12.40"),
                MetadataItem(label: "Sample rate", value: "48 kHz"),
                MetadataItem(label: "Channels", value: "Stereo"),
                MetadataItem(label: "Bit depth", value: "24-bit"),
                MetadataItem(label: "Size", value: "2.4 MB")
            ]
        case .video:
            [
                MetadataItem(label: "Kind", value: "H.264 video"),
                MetadataItem(label: "Resolution", value: "1920 × 1080"),
                MetadataItem(label: "Frame rate", value: "24 fps"),
                MetadataItem(label: "Duration", value: "00:12.40"),
                MetadataItem(label: "Color", value: "Rec. 709"),
                MetadataItem(label: "Size", value: "18.6 MB")
            ]
        case .script:
            [
                MetadataItem(label: "Kind", value: "Markdown"),
                MetadataItem(label: "Words", value: "1,240"),
                MetadataItem(label: "Encoding", value: "UTF-8"),
                MetadataItem(label: "Modified", value: "2 min ago")
            ]
        case .stills:
            [
                MetadataItem(label: "Kind", value: "PNG image"),
                MetadataItem(label: "Dimensions", value: "2048 × 1152"),
                MetadataItem(label: "Frames", value: "8"),
                MetadataItem(label: "Color", value: "Display P3")
            ]
        case .html:
            [
                MetadataItem(label: "Kind", value: "HTML document"),
                MetadataItem(label: "Scenes", value: "8"),
                MetadataItem(label: "Resources", value: "Inline"),
                MetadataItem(label: "Network", value: "Blocked")
            ]
        case .delivery:
            [
                MetadataItem(label: "Kind", value: "MP4 video"),
                MetadataItem(label: "Resolution", value: "1920 × 1080"),
                MetadataItem(label: "Codec", value: "H.264"),
                MetadataItem(label: "Status", value: "Not rendered")
            ]
        }
    }

    private func provenanceRows(for asset: ProductionAsset) -> [MetadataItem] {
        switch asset.kind {
        case .audio:
            [
                MetadataItem(label: "Generated by", value: "Voice Studio"),
                MetadataItem(label: "Model", value: "Sonovo Voice v3"),
                MetadataItem(label: "Voice", value: "Narrator · Calm"),
                MetadataItem(label: "Seed", value: "4821"),
                MetadataItem(label: "Created", value: "Today, 21:12")
            ]
        case .video:
            [
                MetadataItem(label: "Generated by", value: "Video Studio"),
                MetadataItem(label: "Model", value: "Sonovo Motion v2"),
                MetadataItem(label: "Shot", value: "Harbor dawn"),
                MetadataItem(label: "Seed", value: "9314"),
                MetadataItem(label: "Created", value: "Today, 21:08")
            ]
        case .script:
            [
                MetadataItem(label: "Drafted with", value: "Sonovo Writer"),
                MetadataItem(label: "Model", value: "Sonovo Text v2"),
                MetadataItem(label: "Prompt", value: "Coastal dawn, 12 seconds"),
                MetadataItem(label: "Created", value: "Today, 20:54")
            ]
        case .stills:
            [
                MetadataItem(label: "Generated by", value: "Image Studio"),
                MetadataItem(label: "Model", value: "Sonovo Image v4"),
                MetadataItem(label: "Prompt", value: "Harbor at dawn, fog, 35mm"),
                MetadataItem(label: "Seed", value: "2048"),
                MetadataItem(label: "Created", value: "Today, 21:02")
            ]
        case .html:
            [
                MetadataItem(label: "Generated by", value: "Storyboard"),
                MetadataItem(label: "Model", value: "Sonovo Web v1"),
                MetadataItem(label: "Source", value: "8 scene cards"),
                MetadataItem(label: "Created", value: "Today, 21:15")
            ]
        case .delivery:
            [
                MetadataItem(label: "Rendered by", value: "Sonovo Render"),
                MetadataItem(label: "Preset", value: "1080p · H.264"),
                MetadataItem(label: "Status", value: "Not rendered")
            ]
        }
    }
}

private struct NoteCard: View {
    let state: AppState
    let note: ReviewNote

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(note.timecode)
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.10)))
                    .foregroundStyle(Color.accentColor)

                Spacer()

                Button {
                    state.toggleNoteResolved(note.id)
                } label: {
                    Image(systemName: note.isResolved ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(note.isResolved ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(note.isResolved ? "Reopen note" : "Resolve note")
            }

            Text(note.text)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(note.isResolved ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(note.author) · \(note.createdAt)")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(.tertiary)
        }
        .padding(AppTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(Color.appCard.opacity(note.isResolved ? 0.5 : 1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
        )
        .opacity(note.isResolved ? 0.65 : 1)
    }
}
