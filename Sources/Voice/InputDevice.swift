import CoreAudio

enum InputDevice {
    static func inputVolume() -> Float? {
        var deviceID = AudioDeviceID(0)
        var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            0,
            nil,
            &deviceIDSize,
            &deviceID
        ) == noErr else {
            return nil
        }

        var volume = Float32(0)
        var volumeSize = UInt32(MemoryLayout<Float32>.size)
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: 0
        )
        guard AudioObjectGetPropertyData(
            deviceID,
            &volumeAddress,
            0,
            nil,
            &volumeSize,
            &volume
        ) == noErr else {
            return nil
        }
        return volume
    }
}
