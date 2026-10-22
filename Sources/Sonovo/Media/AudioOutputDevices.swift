import CoreAudio
import Foundation

/// One CoreAudio output device that AVPlayer can target.
struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    /// The CoreAudio device UID, which `AVPlayer` accepts.
    let id: String
    let name: String
}

/// Enumerates the system's audio output devices. The settings list is built
/// from real devices instead of a hardcoded menu; "System Default" is the
/// absence of a selection.
enum AudioOutputDevices {
    static func all() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        ) == noErr else {
            return []
        }
        var devices: [AudioOutputDevice] = []
        var seen: Set<String> = []
        for id in ids {
            guard hasOutputChannels(id),
                  let uid = string(
                      id,
                      selector: kAudioDevicePropertyDeviceUID
                  ),
                  let name = string(id, selector: kAudioObjectPropertyName),
                  !uid.isEmpty,
                  seen.insert(uid).inserted else {
                continue
            }
            devices.append(AudioOutputDevice(id: uid, name: name))
        }
        return devices.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func hasOutputChannels(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            device,
            &address,
            0,
            nil,
            &size
        ) == noErr, size > 0 else {
            return false
        }
        let memory = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(
            device,
            &address,
            0,
            nil,
            &size,
            memory
        ) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(
            memory.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func string(
        _ device: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                device,
                &address,
                0,
                nil,
                &size,
                pointer
            )
        }
        guard result == noErr, let value else { return nil }
        return value as String
    }
}
