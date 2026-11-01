import SwiftUI
import SonovoDesignSystem
import SonovoMediaEngine

struct AudioOutputSettingsRow: View {
    @AppStorage("sonovo.audioDevice") private var audioDevice = ""
    @State private var outputDevices: [AudioOutputDevice] = []
    var body: some View {
                SettingsRow {
                    HStack {
                        Text("Output device")
                        Spacer()
                        Picker("", selection: $audioDevice) {
                            Text("System Default").tag("")
                            ForEach(outputDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                            if !audioDevice.isEmpty,
                               !outputDevices.contains(where: {
                                   $0.id == audioDevice
                               }) {
                                Text("Unavailable device")
                                    .tag(audioDevice)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Output device")
                        .frame(width: AppTheme.Layout.settingsPickerWidth)
                    }
                }
        .task { outputDevices = AudioOutputDevices.all() }
    }
}
