import CoreAudio
import Foundation

/// UIDs published by our own HAL plug-in. The app renders *into* the sink; the
/// mic device is what Zoom/Teams/OBS see. Neither may ever be treated as a
/// capture source, or we would build a feedback loop.
enum OCDriver {
    static let sinkUID = "OpenConnectSink_UID"
    static let micUID = "OpenConnectMic_UID"
}

/// A hardware input device the user can use as a channel.
struct AudioInputDevice: Equatable, Identifiable {
    var objectID: AudioObjectID
    var uid: String
    var name: String
    var inputChannels: Int
    var nominalSampleRate: Double

    var id: String { uid }
}

/// Enumerates input devices and reports hot-plug changes.
///
/// Device add/remove is intentionally *not* allowed to tear down the engine: the
/// manager only reports the new device list, and the engine reconciles it by
/// rebuilding the affected channel and nothing else.
final class AudioDeviceManager {
    /// Called on the main queue whenever the set of input devices changes.
    var onChange: (([AudioInputDevice]) -> Void)?

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var installed = false

    // MARK: - Enumeration

    func currentInputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { describe($0) }
            .filter { $0.inputChannels > 0 }
            // Never offer our own virtual devices as a capture source.
            .filter { $0.uid != OCDriver.micUID && $0.uid != OCDriver.sinkUID }
    }

    func sinkDeviceID() -> AudioObjectID? {
        for id in allDeviceIDs() {
            if uid(of: id) == OCDriver.sinkUID { return id }
        }
        return nil
    }

    private func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBytes { raw -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                &dataSize, raw.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids
    }

    private func describe(_ id: AudioObjectID) -> AudioInputDevice? {
        guard let uid = uid(of: id) else { return nil }
        let name = self.name(of: id) ?? uid
        return AudioInputDevice(
            objectID: id,
            uid: uid,
            name: name,
            inputChannels: inputChannelCount(of: id),
            nominalSampleRate: sampleRate(of: id))
    }

    // MARK: - Individual properties

    private func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    func uid(of id: AudioObjectID) -> String? {
        stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    func name(of id: AudioObjectID) -> String? {
        stringProperty(id, kAudioObjectPropertyName)
    }

    func sampleRate(of id: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else {
            return 48_000
        }
        return rate > 0 ? rate : 48_000
    }

    /// Total input channels across all input streams of the device.
    func inputChannelCount(of id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return 0
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, raw) == noErr else {
            return 0
        }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// True while the device is still present and usable.
    func isAlive(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive) == noErr else {
            return false
        }
        return alive != 0
    }

    // MARK: - Hot-plug

    func startObserving() {
        guard !installed else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // Devices frequently appear before their streams are fully
            // described, so settle briefly before reconciling.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.onChange?(self.currentInputDevices())
            }
        }
        listenerBlock = block

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        installed = (status == noErr)
    }

    func stopObserving() {
        guard installed, let block = listenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        installed = false
        listenerBlock = nil
    }

    deinit {
        stopObserving()
    }
}
