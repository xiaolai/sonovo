import SwiftUI

package struct BarIconButton: View {
    package init(systemName: String, help: String, isSelected: Bool = false, tint: Color? = nil,
                 iconSize: CGFloat = AppTheme.TypeScale.sm, width: CGFloat = AppTheme.ControlSize.medium,
                 height: CGFloat = AppTheme.ControlSize.regular, hasRestingBackground: Bool = false,
                 isEnabled: Bool = true, action: @escaping () -> Void) {
        self.systemName = systemName; self.help = help; self.isSelected = isSelected; self.tint = tint
        self.iconSize = iconSize; self.width = width; self.height = height
        self.hasRestingBackground = hasRestingBackground; self.isEnabled = isEnabled; self.action = action
    }

    package let systemName: String
    package let help: String
    package var isSelected = false
    package var tint: Color?
    package var iconSize: CGFloat = AppTheme.TypeScale.sm
    package var width: CGFloat = AppTheme.ControlSize.medium
    package var height: CGFloat = AppTheme.ControlSize.regular
    package var hasRestingBackground = false
    package var isEnabled = true
    package let action: () -> Void

    @State private var isHovering = false

    package var body: some View {
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

package struct MetadataItem: Identifiable {
    package init(label: String, value: String) { self.label = label; self.value = value }
    package let label: String
    package let value: String

    package var id: String { label }
}

package struct MetadataRow: View {
    package init(label: String, value: String) { self.label = label; self.value = value }
    package let label: String
    package let value: String

    package var body: some View {
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

package struct InspectorSection<Content: View>: View {
    package let title: String
    package let content: Content

    package init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    package var body: some View {
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

