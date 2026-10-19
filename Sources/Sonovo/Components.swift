import SwiftUI

struct StatusBadge: View {
    let status: ReviewStatus
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.color)
                .frame(width: 5, height: 5)

            if !compact {
                Text(status.label)
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, compact ? 4 : 6)
        .padding(.vertical, compact ? 2 : 3)
        .background(Capsule().fill(status.color.opacity(0.12)))
        .foregroundStyle(status.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.label)
    }
}

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
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
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
            return Color.accentColor.opacity(0.16)
        }
        return isHovering ? Color.primary.opacity(0.06) : Color.clear
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
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(.secondary)

            Spacer(minLength: AppTheme.Spacing.sm)

            Text(value)
                .font(.system(size: AppTheme.FontSize.sm))
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
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 6) {
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
