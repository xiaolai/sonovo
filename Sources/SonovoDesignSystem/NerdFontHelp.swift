import AppKit
import SwiftUI

package struct NerdFontHelp: View {
    package init() {}
    package var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(
                "Nerd Fonts add the icons used by prompts and CLIs. "
                    + "Recommended: JetBrains Mono Nerd Font."
            )
            .font(.system(size: AppTheme.TypeScale.xs))
            .foregroundStyle(.secondary)
            HStack(spacing: AppTheme.Spacing.sm) {
                Button("Download JetBrains Mono") {
                    NSWorkspace.shared.open(NerdFonts.recommendedDownload)
                }
                Button("All Nerd Fonts…") {
                    NSWorkspace.shared.open(NerdFonts.downloadPage)
                }
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(NerdFonts.installCommand)
                    .font(
                        .system(
                            size: AppTheme.TypeScale.xxs,
                            design: .monospaced
                        )
                    )
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        NerdFonts.installCommand,
                        forType: .string
                    )
                }
            }
        }
    }
}
