import SwiftUI
import WebKit

struct HTMLPreviewView: View {
    let html: String

    @State private var page = HTMLPreviewView.makePage()

    init(html: String = SampleHTML.storyboard) {
        self.html = html
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            browserBar

            WebView(page)
                .webViewMagnificationGestures(.enabled)
                .webViewContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: html) {
                    page.load(html: html)
                }
        }
    }

    private static func makePage() -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.defaultNavigationPreferences.allowsContentJavaScript = false
        return WebPage(configuration: configuration)
    }

    private var browserBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.xxs) {
                Button { } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: AppTheme.Size.addIcon, height: AppTheme.Size.addIcon)
                }
                .disabled(true)
                .help("Back")
                .accessibilityLabel("Back")

                Button { } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: AppTheme.Size.addIcon, height: AppTheme.Size.addIcon)
                }
                .disabled(true)
                .help("Forward")
                .accessibilityLabel("Forward")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "lock.fill")
                    .font(.system(size: AppTheme.TypeScale.micro))
                    .foregroundStyle(.secondary)

                Text("storyboard.html")
                    .font(.system(size: AppTheme.TypeScale.sm))
                    .lineLimit(1)

                Spacer(minLength: AppTheme.Spacing.sm)

                Image(systemName: "arrow.clockwise")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .frame(height: AppTheme.ControlSize.medium)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                    .fill(Color.appCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                    .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
            )
            .frame(maxWidth: AppTheme.Layout.urlBarMaxWidth)

            Spacer()

            Text("Local · No network")
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(height: AppTheme.Size.browserBarHeight)
        .background(AppTheme.Surface.chrome)
    }
}
