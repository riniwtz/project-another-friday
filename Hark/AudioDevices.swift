import Foundation
import CoreAudio

struct AudioDeviceChoice: Identifiable, Hashable {
    let id: String
    let name: String
}

// Lists real macOS Core Audio devices. Choosing one in this UI stores a preference;
// the production AVAudioEngine/SSLAM bridge must apply that routing preference.
enum AudioDevices {
    static func choices(input: Bool) -> [AudioDeviceChoice] {
        var results = [AudioDeviceChoice(id: "system", name: "System Default")]
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount) == noErr,
              byteCount > 0 else { return results }
        let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.stride
        guard count > 0 else { return results }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        // AudioObjectGetPropertyData writes into a C buffer, not a Swift Array
        // value. Pin the contiguous element storage explicitly.
        let readStatus = deviceIDs.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount,
                UnsafeMutableRawPointer(buffer.baseAddress!) // count is nonzero
            )
        }
        guard readStatus == noErr else { return results }
        let returnedCount = min(count, Int(byteCount) / MemoryLayout<AudioDeviceID>.stride)
        for deviceID in deviceIDs.prefix(returnedCount) where supportsStream(deviceID, input: input) {
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            // Core Audio writes a retained CFStringRef to this output slot.
            // Use an unmanaged pointer-sized slot, not the address of a Swift
            // reference value (which would trigger an unsafe raw-pointer warning).
            var rawName: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &rawName) { pointer in
                AudioObjectGetPropertyData(
                    deviceID, &nameAddress, 0, nil, &size,
                    UnsafeMutableRawPointer(pointer)
                )
            }
            guard status == noErr, let rawName else { continue }
            // The kAudioObjectPropertyName contract makes callers responsible
            // for releasing the returned CFString.
            let name = rawName.takeRetainedValue() as String
            results.append(AudioDeviceChoice(id: String(deviceID), name: name))
        }
        return results
    }

    private static func supportsStream(_ deviceID: AudioDeviceID, input: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr &&
               size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }
}
