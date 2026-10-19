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
        HStack(alignment: .top, spacing: AppTheme.Spacing.zero) {
            ScrollView {
                page
                    .frame(maxWidth: AppTheme.Layout.scriptPageMaxWidth)
                    .padding(.horizontal, AppTheme.Spacing.xl)
                    .padding(.vertical, AppTheme.Spacing.xl)
                    .frame(maxWidth: .infinity)
            }

            formattingRail
                .padding(.top, AppTheme.Spacing.xl)
                .padding(.trailing, AppTheme.Spacing.md)
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            if state.scriptRendered {
                renderedScript
            } else {
                sourceScript
            }
        }
        .padding(.horizontal, AppTheme.Spacing.s48)
        .padding(.vertical, AppTheme.Spacing.s42)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appText)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.surface, style: .continuous)
                .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.surface, style: .continuous))
        .appShadow(AppTheme.Shadow.card)
    }

    private var renderedScript: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            Text("TIDEWATER")
                .font(.system(size: AppTheme.TypeScale.displayLarge, weight: .bold, design: .serif))
                .tracking(AppTheme.Tracking.hero)

            Text("EPISODE 01 — THE HARBOR AT SIX")
                .font(.system(size: AppTheme.TypeScale.xs, weight: .semibold))
                .tracking(AppTheme.Tracking.displayWider)
                .foregroundStyle(.secondary)
                .padding(.top, AppTheme.Spacing.s6)

            HStack(spacing: AppTheme.Spacing.s6) {
                Text("Narration draft")
                Text("·")
                Text("1,240 words")
                Text("·")
                Text("Updated 2 min ago")
            }
            .font(.system(size: AppTheme.TypeScale.xs))
            .foregroundStyle(.tertiary)
            .padding(.top, AppTheme.Spacing.s10)

            Hairline()
                .padding(.vertical, AppTheme.Spacing.xl)

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
                .padding(.top, AppTheme.Spacing.s26)

            action("The town arrives in pieces: a light, a door, a kettle.")

            dialogue("And the day begins the way it always has.")

            Text("END OF DRAFT")
                .font(.system(size: AppTheme.TypeScale.xxs, weight: .semibold))
                .tracking(AppTheme.Tracking.display)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, AppTheme.Spacing.s36)
        }
        .textSelection(.enabled)
    }

    private var sourceScript: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("MARKDOWN SOURCE")
                    .font(.system(size: AppTheme.TypeScale.xxs, weight: .semibold))
                    .tracking(AppTheme.Tracking.widest)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("UTF-8")
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.tertiary)
            }

            Hairline()

            Text(source)
                .font(.system(size: AppTheme.TypeScale.body, design: .monospaced))
                .foregroundStyle(.primary)
                .lineSpacing(AppTheme.LineSpacing.tight)
                .textSelection(.enabled)
        }
    }

    private func sceneHeading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.TypeScale.sm, weight: .bold))
            .tracking(AppTheme.Tracking.widest)
            .padding(.bottom, AppTheme.Spacing.s10)
    }

    private func action(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.TypeScale.lg, design: .serif))
            .lineSpacing(AppTheme.LineSpacing.relaxed)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, AppTheme.Spacing.s18)
    }

    private func dialogue(_ text: String) -> some View {
        VStack(spacing: AppTheme.Spacing.s7) {
            Text("NARRATOR (V.O.)")
                .font(.system(size: AppTheme.TypeScale.xs, weight: .semibold))
                .tracking(AppTheme.Tracking.wide)

            Text(text)
                .font(.system(size: AppTheme.TypeScale.lg, design: .serif))
                .lineSpacing(AppTheme.LineSpacing.relaxed)
                .multilineTextAlignment(.center)
                .frame(maxWidth: AppTheme.Layout.dialogueMaxWidth)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppTheme.Spacing.s10)
    }

    private func inlineNote(timecode: String, text: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "text.bubble")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(AppTheme.Palette.needsReview)
                .padding(.top, AppTheme.Spacing.hairline)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("NOTE · \(timecode)")
                    .font(.system(size: AppTheme.TypeScale.micro, weight: .semibold))
                    .tracking(AppTheme.Tracking.normal)
                    .foregroundStyle(AppTheme.Palette.needsReview)
                Text(text)
                    .font(.system(size: AppTheme.TypeScale.sm))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: AppTheme.Spacing.zero)
        }
        .padding(AppTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                .fill(AppTheme.Palette.needsReview.opacity(AppTheme.Opacity.veil))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: AppTheme.Radius.line)
                .fill(AppTheme.Palette.needsReview.opacity(AppTheme.Opacity.heavySoft))
                .frame(width: AppTheme.BorderWidth.thick)
        }
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    private var formattingRail: some View {
        VStack(spacing: AppTheme.Spacing.xxs) {
            formatButton("bold", help: "Bold")
            formatButton("italic", help: "Italic")
            formatButton("strikethrough", help: "Strikethrough")
            formatButton("link", help: "Link")
            formatButton("list.bullet", help: "List")
            formatButton("text.quote", help: "Quote")
            formatButton("chevron.left.forwardslash.chevron.right", help: "Code")

            VStack(spacing: AppTheme.Spacing.xxs) {
                modeButton(rendered: true)
                modeButton(rendered: false)
            }
            .padding(.top, AppTheme.Spacing.sm)
        }
        .padding(.horizontal, AppTheme.Spacing.xs)
        .padding(.vertical, AppTheme.Spacing.s6)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.surface, style: .continuous)
                .fill(AppTheme.Surface.floating)
        )
        .appShadow(AppTheme.Shadow.floating)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Markdown formatting")
    }

    private func modeButton(rendered: Bool) -> some View {
        let isSelected = state.scriptRendered == rendered

        return Button {
            state.scriptRendered = rendered
        } label: {
            Image(systemName: rendered ? "doc.richtext" : "doc.plaintext")
                .font(.system(size: AppTheme.TypeScale.body, weight: .medium))
                .frame(width: AppTheme.ControlSize.medium, height: AppTheme.ControlSize.medium)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.micro, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(AppTheme.Opacity.muted) : Color.clear)
                )
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(rendered ? "Rendered" : "Source")
        .accessibilityLabel(rendered ? "Rendered" : "Source")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func formatButton(_ symbol: String, help: String) -> some View {
        Button {
            activeFormat = activeFormat == symbol ? nil : symbol
        } label: {
            Image(systemName: symbol)
                .font(.system(size: AppTheme.TypeScale.caption, weight: .medium))
                .frame(width: AppTheme.Size.formatButtonWidth, height: AppTheme.Size.formatButtonHeight)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.micro, style: .continuous)
                        .fill(activeFormat == symbol ? Color.accentColor.opacity(AppTheme.Opacity.muted) : Color.clear)
                )
                .foregroundStyle(activeFormat == symbol ? Color.accentColor : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
