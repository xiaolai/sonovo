import SwiftUI

struct BarIconButton: View {
    let systemName: String
    let help: String
    var isSelected = false
    var tint: Color?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
                .frame(width: AppTheme.ControlSize.medium, height: AppTheme.ControlSize.regular)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                        .fill(backgroundColor)
                )
                .foregroundStyle(isSelected ? Color.accentColor : (tint ?? Color.primary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .help(help)
        .accessibilityLabel(help)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(AppTheme.Opacity.muted)
        }
        return isHovering ? Color.primary.opacity(AppTheme.Opacity.ghostSoft) : Color.clear
    }
}

struct MetadataItem: Identifiable {
    let label: String
    let value: String

    var id: String { label }
}

struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)

            Spacer(minLength: AppTheme.Spacing.sm)

            Text(value)
                .font(.system(size: AppTheme.TypeScale.sm))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s7) {
            Text(title.uppercased())
                .font(.system(size: AppTheme.TypeScale.xxs, weight: .semibold))
                .tracking(AppTheme.Tracking.normal)
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.s6) {
                content
            }
        }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.appSeparator)
            .frame(height: AppTheme.BorderWidth.hairline)
    }
}
