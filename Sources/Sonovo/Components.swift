import SwiftUI

struct BarIconButton: View {
    let systemName: String
    let help: String
    var isSelected = false
    var tint: Color?
    var iconSize: CGFloat = AppTheme.TypeScale.sm
    var width: CGFloat = AppTheme.ControlSize.medium
    var height: CGFloat = AppTheme.ControlSize.regular
    var hasRestingBackground = false
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                        .fill(backgroundColor)
                )
                .foregroundStyle(isSelected ? Color.accentColor : (tint ?? Color.primary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(
            isEnabled ? AppTheme.Opacity.full : AppTheme.Opacity.half
        )
        .onHover { hovering in
            isHovering = isEnabled && hovering
        }
        .help(help)
        .accessibilityLabel(help)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(AppTheme.Opacity.muted)
        }
        if isHovering {
            return Color.primary.opacity(
                hasRestingBackground
                    ? AppTheme.Opacity.soft
                    : AppTheme.Opacity.ghostSoft
            )
        }
        return hasRestingBackground
            ? Color.primary.opacity(AppTheme.Opacity.ghost)
            : Color.clear
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

