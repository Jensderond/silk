import AudioToolbox
import CoreAudio

/// Volume of the default output device (CoreAudio), for the `volume` command. Thread-safe.
public enum AudioOutput {
    /// Volumes below this mute the device when `autoMuteUnmute` is on (ISSoundAdditions parity).
    static let muteThreshold: Float = 0.005

    /// Main volume in 0...1; nil when there's no output device or it has no volume control.
    public static var volume: Float? {
        guard let device = defaultOutputDevice else { return nil }
        var volume: Float32 = 0
        return get(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, &volume) ? volume : nil
    }

    /// Sets the main volume (clamped to 0...1). With `autoMuteUnmute`, setting (almost) zero mutes
    /// and setting a positive volume on a muted device unmutes it. Returns false on failure.
    @discardableResult
    public static func setVolume(_ newValue: Float, autoMuteUnmute: Bool = true) -> Bool {
        guard let device = defaultOutputDevice else { return false }
        var volume = Float32(min(max(newValue, 0), 1))
        guard set(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, &volume) else { return false }
        if autoMuteUnmute, let isMuted {
            let shouldMute = volume < muteThreshold
            if shouldMute != isMuted { setMuted(shouldMute) }
        }
        return true
    }

    /// nil when the device has no mute control.
    public static var isMuted: Bool? {
        guard let device = defaultOutputDevice else { return nil }
        var muted: UInt32 = 0
        return get(device, kAudioDevicePropertyMute, &muted) ? muted != 0 : nil
    }

    @discardableResult
    public static func setMuted(_ muted: Bool) -> Bool {
        guard let device = defaultOutputDevice else { return false }
        var value: UInt32 = muted ? 1 : 0
        return set(device, kAudioDevicePropertyMute, &value)
    }

    private static var defaultOutputDevice: AudioDeviceID? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static func get<T: BitwiseCopyable>(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = outputAddress(selector)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
    }

    private static func set<T: BitwiseCopyable>(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = outputAddress(selector)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue
        else { return false }
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }
}
