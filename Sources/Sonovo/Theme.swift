import SwiftUI

enum AppTheme {
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
    }

    enum FontSize {
        static let xxs: CGFloat = 9
        static let xs: CGFloat = 10
        static let sm: CGFloat = 11
        static let body: CGFloat = 12
        static let md: CGFloat = 13
        static let lg: CGFloat = 15
        static let xl: CGFloat = 17
        static let xxl: CGFloat = 22
        static let display: CGFloat = 28
    }

    enum Opacity {
        static let subtle: Double = 0.04
        static let faint: Double = 0.08
        static let muted: Double = 0.16
        static let medium: Double = 0.28
        static let strong: Double = 0.6
        static let prominent: Double = 0.9
    }

    enum BorderWidth {
        static let hairline: CGFloat = 0.5
        static let thin: CGFloat = 1
        static let medium: CGFloat = 1.5
        static let thick: CGFloat = 2
    }

    static let sidebarWidth: CGFloat = 264
    static let sidebarMinWidth: CGFloat = 224
    static let sidebarMaxWidth: CGFloat = 340
    static let inspectorWidth: CGFloat = 304
    static let inspectorMinWidth: CGFloat = 264
    static let inspectorMaxWidth: CGFloat = 380
    static let tabBarHeight: CGFloat = 34
    static let breadcrumbHeight: CGFloat = 28
    static let transportHeight: CGFloat = 46
    static let toolbarControlHeight: CGFloat = 24
    static let pageMaxWidth: CGFloat = 760
}

extension Color {
    static var appWindow: Color { Color(nsColor: .windowBackgroundColor) }
    static var appContent: Color { Color(nsColor: .underPageBackgroundColor) }
    static var appCard: Color { Color(nsColor: .controlBackgroundColor) }
    static var appText: Color { Color(nsColor: .textBackgroundColor) }
    static var appLabel: Color { Color(nsColor: .labelColor) }
    static var appSecondaryLabel: Color { Color(nsColor: .secondaryLabelColor) }
    static var appTertiaryLabel: Color { Color(nsColor: .tertiaryLabelColor) }
    static var appSeparator: Color { Color(nsColor: .separatorColor) }
    static var appSelection: Color { Color(nsColor: .selectedContentBackgroundColor) }
}

extension View {
    func appCardStyle() -> some View {
        background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                .fill(Color.appCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
        )
    }

    func appHairlineOverlay(_ edges: Edge.Set = .all) -> some View {
        overlay(alignment: .top) {
            if edges.contains(.top) {
                Rectangle()
                    .fill(Color.appSeparator)
                    .frame(height: AppTheme.BorderWidth.hairline)
            }
        }
    }
}
