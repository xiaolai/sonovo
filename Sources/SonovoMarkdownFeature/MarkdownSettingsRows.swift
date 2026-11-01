import SwiftUI
import SonovoDesignSystem

struct MarkdownSettingsRows: View {
    @AppStorage("sonovo.markdownRendered") private var markdownRendered = true
    @AppStorage("sonovo.wrapLines") private var wrapLines = true
    @AppStorage("sonovo.markdownFocusMode") private var markdownFocusMode = false
    @AppStorage("sonovo.markdownTypewriter") private var markdownTypewriter = false
    @AppStorage("sonovo.markdownLineNumbers") private var markdownLineNumbers = false
    var body: some View {
        Group {
                SettingsRow {
                    Toggle("Open Markdown rendered", isOn: $markdownRendered)
                    Text("Start in the rendered document view instead of source.")
                }
                SettingsRow {
                    Toggle("Wrap long lines", isOn: $wrapLines)
                    Text("Wrap source lines to the width of the editor.")
                }
                SettingsRow {
                    Toggle("Focus mode", isOn: $markdownFocusMode)
                    Text("Dim Markdown blocks outside the current one.")
                }
                SettingsRow {
                    Toggle("Typewriter mode", isOn: $markdownTypewriter)
                    Text("Keep the caret near 40% of the editor.")
                }
                SettingsRow {
                    Toggle("Line numbers", isOn: $markdownLineNumbers)
                    Text("Show source line numbers in the gutter.")
                }
        }
        .onChange(of: wrapLines) { _, _ in notify() }
        .onChange(of: markdownFocusMode) { _, _ in notify() }
        .onChange(of: markdownTypewriter) { _, _ in notify() }
        .onChange(of: markdownLineNumbers) { _, _ in notify() }
    }
    private func notify() { NotificationCenter.default.post(name: .sonovoEditorPreferencesChanged, object: nil) }
}
