import SwiftUI
import WebKit

struct HTMLPreviewView: View {
    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            browserBar

            HTMLWebView(html: SampleHTML.storyboard)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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

private struct HTMLWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = true
        webView.loadHTMLString(html, baseURL: nil)

        context.coordinator.lastHTML = html
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator {
        var lastHTML: String?
    }
}
