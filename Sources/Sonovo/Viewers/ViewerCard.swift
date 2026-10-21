import SwiftUI

/// One card treatment for every document viewer. Image, PDF, local web,
/// Quick Look, metadata, and comparison all sat inside the same background,
/// clipping, border, and padding block.
struct ViewerCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(
                    cornerRadius: AppTheme.Radius.surface,
                    style: .continuous
                )
                .fill(Color.appText)
            )
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
            .padding(AppTheme.Spacing.lg)
    }
}

extension View {
    func viewerCard() -> some View {
        modifier(ViewerCard())
    }
}
