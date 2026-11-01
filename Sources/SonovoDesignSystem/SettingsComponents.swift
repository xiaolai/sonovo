import SwiftUI

package struct SettingsPaneHeader: View {
    package init(title: String, detail: String) { self.title = title; self.detail = detail }
    package let title: String
    package let detail: String

    package var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(title)
                .font(.system(size: AppTheme.TypeScale.xl, weight: .semibold))
            Text(detail)
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)
        }
    }
}

package struct SettingsGroup<Content: View>: View {
    package let content: Content

    package init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    package var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            content
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.panel, style: .continuous)
                .fill(Color.appCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.panel, style: .continuous)
                .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
        )
    }
}

package struct SettingsRow<Content: View>: View {
    package let content: Content

    package init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s3) {
            content
        }
        .font(.system(size: AppTheme.TypeScale.sm))
        .padding(.vertical, AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
