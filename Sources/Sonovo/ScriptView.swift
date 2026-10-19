import SwiftUI

struct ScriptView: View {
    @Bindable var state: AppState

    @State private var activeFormat: String?

    private let source = """
    # TIDEWATER

    **Episode 01 — The Harbor at Six**

    Narration draft · 1,240 words

    ## EXT. HARBOR — DAWN

    Fog sits on the water. A single skiff cuts through the gray.

    NARRATOR (V.O.)
    The harbor wakes before the town does.

    NARRATOR (V.O.)
    Fog sits on the water like a held breath.

    > Note · 00:03.20 — "Held breath" lands a little flat.

    NARRATOR (V.O.)
    By six, the first boat is already out.

    ## EXT. HARBOR — SIX O'CLOCK

    The town arrives in pieces: a light, a door, a kettle.

    NARRATOR (V.O.)
    And the day begins the way it always has.
    """

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                page
                    .frame(maxWidth: 720)
                    .padding(.horizontal, AppTheme.Spacing.xl)
                    .padding(.vertical, AppTheme.Spacing.xl)
                    .frame(maxWidth: .infinity)
            }

            formattingBar
                .padding(.top, AppTheme.Spacing.lg)
                .padding(.trailing, AppTheme.Spacing.xl)
        }
        .background(Color.appContent)
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.scriptRendered {
                renderedScript
            } else {
                sourceScript
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 42)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appText)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
    }

    private var renderedScript: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TIDEWATER")
                .font(.system(size: 30, weight: .bold, design: .serif))
                .tracking(3)

            Text("EPISODE 01 — THE HARBOR AT SIX")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            HStack(spacing: 6) {
                Text("Narration draft")
                Text("·")
                Text("1,240 words")
                Text("·")
                Text("Updated 2 min ago")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .padding(.top, 10)

            Hairline()
                .padding(.vertical, 24)

            sceneHeading("EXT. HARBOR — DAWN")

            action("Fog sits on the water. A single skiff cuts through the gray.")

            dialogue("The harbor wakes before the town does.")
            dialogue("Fog sits on the water like a held breath.")

            inlineNote(
                timecode: "00:03.20",
                text: "“Held breath” lands a little flat. Try a warmer read."
            )

            dialogue("By six, the first boat is already out.")

            sceneHeading("EXT. HARBOR — SIX O'CLOCK")
                .padding(.top, 26)

            action("The town arrives in pieces: a light, a door, a kettle.")

            dialogue("And the day begins the way it always has.")

            Text("END OF DRAFT")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
        }
        .textSelection(.enabled)
    }

    private var sourceScript: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("MARKDOWN SOURCE")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("UTF-8")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Hairline()

            Text(source)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .textSelection(.enabled)
        }
    }

    private func sceneHeading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(1.0)
            .padding(.bottom, 10)
    }

    private func action(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, design: .serif))
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 18)
    }

    private func dialogue(_ text: String) -> some View {
        VStack(spacing: 7) {
            Text("NARRATOR (V.O.)")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)

            Text(text)
                .font(.system(size: 15, design: .serif))
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private func inlineNote(timecode: String, text: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "text.bubble")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("NOTE · \(timecode)")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(.orange)
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(AppTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .fill(Color.orange.opacity(0.07))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.orange.opacity(0.7))
                .frame(width: 2)
        }
        .padding(.vertical, 8)
    }

    private var formattingBar: some View {
        HStack(spacing: 1) {
            formatButton("bold", help: "Bold")
            formatButton("italic", help: "Italic")
            formatButton("strikethrough", help: "Strikethrough")
            formatButton("link", help: "Link")
            formatButton("list.bullet", help: "List")
            formatButton("text.quote", help: "Quote")
            formatButton("chevron.left.forwardslash.chevron.right", help: "Code")

            Rectangle()
                .fill(Color.appSeparator)
                .frame(width: 1, height: 14)
                .padding(.horizontal, 4)

            Picker("Markdown Mode", selection: $state.scriptRendered) {
                Text("Rendered").tag(true)
                Text("Source").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 118)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Capsule().fill(.regularMaterial))
        .overlay(
            Capsule().strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Markdown formatting")
    }

    private func formatButton(_ symbol: String, help: String) -> some View {
        Button {
            activeFormat = activeFormat == symbol ? nil : symbol
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(activeFormat == symbol ? Color.accentColor.opacity(0.16) : Color.clear)
                )
                .foregroundStyle(activeFormat == symbol ? Color.accentColor : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
