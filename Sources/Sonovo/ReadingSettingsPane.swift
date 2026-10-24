import Foundation
import SonovoCore
import SwiftUI

/// The Reading pane: theme selection, shared reading overrides, preview,
/// and the user-theme folder actions.
struct ReadingSettingsPane: View {
    @AppStorage(PreferenceKey.readingTheme) private var readingThemeID = "paper"
    @AppStorage(PreferenceKey.readingBodySize) private var readingBodySize = 0.0
    @AppStorage(PreferenceKey.readingMeasure) private var readingMeasure = 0.0
    @AppStorage(PreferenceKey.readingThemeRevision) private var readingThemeRevision = 0
    @State private var themeCatalog = MarkdownThemeCatalog.empty
    @State private var themeMessage: String?
    /// Unstructured button tasks can outlive this pane. An inactive pane
    /// must not invalidate a successor's scan or publish over it.
    @State private var isActive = true

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            SettingsPaneHeader(
                title: "Reading",
                detail: "Choose how rendered Markdown looks. Source editing "
                    + "keeps its own text settings."
            )

            if themeCatalog.themes.isEmpty {
                ProgressView("Loading themes…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, AppTheme.Spacing.lg)
            } else {
                themeContent
            }
        }
        .onAppear { isActive = true }
        .onDisappear { isActive = false }
        .task {
            if themeCatalog.themes.isEmpty {
                await scan()
            }
        }
    }

    private var themeContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            SettingsGroup {
                SettingsRow {
                    HStack {
                        Text("Theme")
                        Spacer()
                        Menu {
                            ForEach(themeCatalog.themes) { theme in
                                Button(theme.name) {
                                    readingThemeID = theme.id
                                    MarkdownThemeStore.shared.cache(theme)
                                    themeMessage = nil
                                }
                            }
                        } label: {
                            HStack(spacing: AppTheme.Spacing.xs) {
                                Text(currentReadingTheme.name)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(
                                        .system(
                                            size: AppTheme.TypeScale.micro,
                                            weight: .semibold
                                        )
                                    )
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                SettingsRow {
                    ReadingOverrideRow(
                        label: "Body size",
                        valueText: bodySizeText,
                        value: bodySizeBinding,
                        range: MarkdownThemeLimits.bodySize,
                        step: 0.5,
                        reset: { readingBodySize = 0 }
                    )
                }
                SettingsRow {
                    ReadingOverrideRow(
                        label: "Measure",
                        valueText: measureText,
                        value: measureBinding,
                        range: MarkdownThemeLimits.measure,
                        step: 10,
                        reset: { readingMeasure = 0 }
                    )
                }
                SettingsRow {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Button("Open Themes Folder") {
                            MarkdownThemeStore.shared.openThemesFolder()
                        }
                        Button("Reload") {
                            reloadThemes()
                        }
                        Button("Duplicate Theme") {
                            duplicateSelectedTheme()
                        }
                        .disabled(selectedThemeMissing)
                        Spacer()
                    }
                }
            }

            if let themeMessage {
                Text(themeMessage)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
            }
            if selectedThemeMissing {
                Text(
                    "The selected theme \"\(readingThemeID)\" is missing; "
                        + (selectedThemeIsFallback
                            ? "Paper is shown. "
                            : "the last loaded version is shown. ")
                        + "Choose another theme or restore the file."
                )
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(AppTheme.Palette.warning)
            }
            ForEach(
                Array(themeCatalog.issues.enumerated()),
                id: \.offset
            ) { item in
                Text(item.element)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(AppTheme.Palette.warning)
            }
            ForEach(
                Array(currentThemeWarnings.enumerated()),
                id: \.offset
            ) { item in
                Text(item.element)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(AppTheme.Palette.warning)
            }

            readingPreview

            Text(
                "Themes are JSON files. The built-ins are Paper, Book, "
                    + "Editorial, and Draft. Copies you make live in "
                    + "Application Support and can be edited there."
            )
            .font(.system(size: AppTheme.TypeScale.xs))
            .foregroundStyle(.tertiary)
        }
    }

    private var readingPreview: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Preview")
                .font(
                    .system(
                        size: AppTheme.TypeScale.xs,
                        weight: .semibold
                    )
                )
                .foregroundStyle(.secondary)
            MarkdownViewer(
                ast: Self.previewDocument.ast,
                headings: Self.previewDocument.headings,
                theme: previewTheme,
                onOpenExternalURL: { _ in }
            )
            .frame(height: AppTheme.Layout.settingsReadingPreviewHeight)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: AppTheme.Radius.surface,
                    style: .continuous
                )
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: AppTheme.Radius.surface,
                    style: .continuous
                )
                .strokeBorder(
                    Color.appSeparator,
                    lineWidth: AppTheme.BorderWidth.hairline
                )
            )
        }
    }

    /// The pane only renders content after the catalog loads, so this never
    /// performs a file read on the main actor. A missing selection falls back
    /// to the first loaded theme; Settings says the id is missing.
    private var currentReadingTheme: MarkdownTheme {
        // Prefer the cached theme for a selected file that is missing from
        // the catalog: the viewer renders that cached theme, so the preview
        // and controls must show the same one rather than Paper.
        themeCatalog.themes.first { $0.id == readingThemeID }
            ?? MarkdownThemeStore.shared.cachedTheme(id: readingThemeID)
            ?? themeCatalog.themes.first
            ?? MarkdownThemeStore.shared.defaultTheme()
    }

    private var previewTheme: MarkdownTheme {
        currentReadingTheme.withOverrides(
            bodySize: readingBodySize,
            measure: readingMeasure
        )
    }

    private var currentThemeWarnings: [String] {
        currentReadingTheme.warnings
    }

    /// The stored id is neither built in nor present on disk. The viewer
    /// falls back to Paper; say so instead of showing Paper silently.
    private var selectedThemeMissing: Bool {
        !MarkdownThemeStore.builtInOrder.contains(readingThemeID)
            && !themeCatalog.themes.contains { $0.id == readingThemeID }
    }

    /// True when the cached answer under the selected id is a fallback
    /// (Paper), not an earlier version of the user's own theme.
    private var selectedThemeIsFallback: Bool {
        guard let cached = MarkdownThemeStore.shared.cachedTheme(
            id: readingThemeID
        ) else {
            return true
        }
        return cached.id != readingThemeID
    }

    /// The controls read the same resolved values the preview renders, so a
    /// displayed size cannot disagree with the document.
    private var bodySizeBinding: Binding<Double> {
        Binding(
            get: { Double(previewTheme.bodySize) },
            set: { readingBodySize = $0 }
        )
    }

    private var measureBinding: Binding<Double> {
        Binding(
            get: { Double(previewTheme.measure) },
            set: { readingMeasure = $0 }
        )
    }

    private var bodySizeText: String {
        pointsLabel(Double(previewTheme.bodySize))
    }

    private var measureText: String {
        pointsLabel(Double(previewTheme.measure))
    }

    private func pointsLabel(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.05 {
            return "\(Int(rounded)) pt"
        }
        return String(format: "%.1f pt", value)
    }

    /// Catalog scans touch every user file. Run them on a fresh store off
    /// the main actor. Publishing then replaces the shared cache in one
    /// main-actor step, so any selection made while the scan was in flight is
    /// already cached and no document re-reads a file.
    private func loadCatalog() async -> MarkdownThemeCatalog {
        await Task.detached(priority: .userInitiated) {
            MarkdownThemeStore().catalog()
        }.value
    }

    /// Publishes a catalog and invalidates open documents. Every suspension
    /// happens before the generation check; after it, cache, catalog, and
    /// revision are written in one main-actor step. A scan superseded during
    /// the fallback load therefore cannot overwrite a newer publication.
    private func publishAndInvalidate(
        _ catalog: MarkdownThemeCatalog,
        generation: Int? = nil
    ) async {
        let id = readingThemeID
        var fallback: MarkdownTheme?
        if !catalog.themes.contains(where: { $0.id == id }),
           MarkdownThemeStore.shared.cachedTheme(id: id) == nil {
            fallback = await Task.detached(priority: .userInitiated) {
                MarkdownThemeStore().theme(id: id)
            }.value
        }
        if let generation,
           !MarkdownThemeStore.shared.isCurrentCatalogScan(generation) {
            return
        }
        // Update in place. Clearing first would evict a theme selected while
        // the scan was in flight and force the viewer into a main-actor read.
        for theme in catalog.themes {
            MarkdownThemeStore.shared.cache(theme)
        }
        if let fallback {
            MarkdownThemeStore.shared.cache(fallback, for: id)
        }
        themeCatalog = catalog
        readingThemeRevision += 1
    }

    /// Runs one catalog scan. The generation lives in the shared store, so a
    /// replaced pane's scan cannot publish over a newer one.
    private func scan() async {
        guard isActive else { return }
        let generation = MarkdownThemeStore.shared.beginCatalogScan()
        let catalog = await loadCatalog()
        guard isActive,
              MarkdownThemeStore.shared.isCurrentCatalogScan(generation) else {
            return
        }
        await publishAndInvalidate(catalog, generation: generation)
    }

    private func reloadThemes() {
        Task { await scan() }
    }

    private func duplicateSelectedTheme() {
        let sourceID = readingThemeID
        Task {
            do {
                let newID = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try MarkdownThemeStore().duplicateTheme(id: sourceID)
                }.value
                guard isActive else { return }
                let created = await Task.detached(
                    priority: .userInitiated
                ) {
                    MarkdownThemeStore().theme(id: newID)
                }.value
                guard isActive else { return }
                readingThemeID = newID
                // This generation both invalidates in-flight scans and
                // guards the publication if it suspends for a fallback.
                let generation = MarkdownThemeStore.shared.beginCatalogScan()
                await publishAndInvalidate(
                    MarkdownThemeCatalog(
                        themes: themeCatalog.themes + [created],
                        issues: themeCatalog.issues
                    ),
                    generation: generation
                )
                themeMessage = "Created \(newID).json in the themes folder."
                Task { await scan() }
            } catch {
                themeMessage = "\(error)"
            }
        }
    }

    private static let previewDocument: (
        ast: SonovoAST,
        headings: HeadingIndex
    ) = {
        let source = """
        # A quiet place to read

        Typography is most of the work: **weight**, *emphasis*, `inline
        code`, and a [link](https://example.com) in a measured line.

        > A quote should feel like a pause, not a box.

        ## A section

        - One idea
        - Another idea

        ```swift
        let measure = 660
        ```

        | Element | Role |
        |---|---|
        | Measure | About 66 characters |
        | Rhythm | One vertical scale |

        ---
        """
        let parsed = MarkdownParser.parse(source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        return (ast, HeadingIndex(ast: ast))
    }()
}

private struct ReadingOverrideRow: View {
    let label: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let reset: () -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Text(label)
                .frame(
                    width: AppTheme.Layout.settingsRowLabelWidth,
                    alignment: .leading
                )
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(label)
            Text(valueText)
                .monospacedDigit()
            Button("Theme Default", action: reset)
                .controlSize(.small)
        }
    }
}
