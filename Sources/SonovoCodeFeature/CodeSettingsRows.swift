import SwiftUI
import SonovoDesignSystem

struct CodeSettingsRows: View {
    @AppStorage("sonovo.codeTabWidth") private var codeTabWidth = AppTheme.Code.tabWidthDefault
    @AppStorage("sonovo.codeUsesTabs") private var codeUsesTabs = false
    @AppStorage("sonovo.codeWrapLines") private var codeWrapLines = false
    var body: some View { Group {
                SettingsRow {
                    HStack {
                        Text("Code tab width")
                        Spacer()
                        Stepper(
                            value: codeTabWidthBinding,
                            in: AppTheme.Code.tabWidthRange
                        ) {
                            Text("\(codeTabWidthBinding.wrappedValue)")
                                .monospacedDigit()
                        }
                        .fixedSize()
                    }
                }
                SettingsRow {
                    Toggle("Insert tabs in code", isOn: $codeUsesTabs)
                    Text(
                        "Use tab characters instead of spaces when Tab is "
                            + "pressed in the code editor."
                    )
                }
                SettingsRow {
                    Toggle("Wrap code lines", isOn: $codeWrapLines)
                    Text(
                        "Wrap long code lines instead of scrolling "
                            + "horizontally."
                    )
                }
    } }
    private var codeTabWidthBinding: Binding<Int> {
        Binding(
            get: { AppTheme.Code.clampedTabWidth(codeTabWidth) },
            set: { codeTabWidth = AppTheme.Code.clampedTabWidth($0) }
        )
    }
}
