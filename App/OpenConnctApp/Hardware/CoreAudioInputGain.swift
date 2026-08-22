import CoreAudio
import Foundation

/// Drives a microphone's own input gain stage.
///
/// The capability seam this sits behind was originally sketched around a
/// vendor-specific USB HID protocol, on the assumption that device gain was not
/// reachable any other way. On the hardware this was developed against that
/// turned out to be wrong: both microphones expose a writable input gain through
/// the USB Audio Class feature unit, which CoreAudio publishes as an ordinary
/// device property. That route is public, documented, needs no reverse
/// engineering, cannot brick a device by writing an unknown report — and works
/// on any class-compliant microphone rather than one vendor's. It is strictly
/// better, so it is what this uses. `docs/hardware-gain.md` records what was
/// measured, including what is *not* reachable this way.
///
/// Everything slow here runs off the main thread and far away from the audio
/// thread. That is not a stylistic preference: writing this property was
/// measured at a median of 1.7 ms but a worst case of **1007 ms** on one of the
/// two devices. A call like that on the main thread is a visible hang; on the
/// render thread it is a dropout.
///
/// Thread ownership, stated once because it is the easiest thing here to get
/// wrong: `capabilities` and `listeners` belong to the main thread and are only
/// touched from it. `pending` and `inFlight` belong to `queue`. Nothing is
/// shared between the two — the slow path captures the `AudioObjectID` it needs
/// by value rather than looking it up.
final class CoreAudioInputGain {

    /// Called on the main queue whenever a device's reported gain changes —
    /// whether because we asked for it or because something else did. `nil`
    /// means the value could not be read, which the caller should treat as
    /// "there is no hardware stage right now" rather than as an error.
    var onReportedGainChanged: ((_ deviceUID: String, _ db: Float?) -> Void)?

    /// Serial, and deliberately not `.userInteractive`. Work here is slow by
    /// nature and must never contend with the audio or UI threads.
    private let queue = DispatchQueue(label: "audio.openconnct.hardwaregain", qos: .utility)

    // Main thread only.
    private var capabilities: [String: (deviceID: AudioObjectID, range: HardwareGainRange)] = [:]
    private var listeners: [String: (AudioObjectID, AudioObjectPropertyListenerBlock)] = [:]

    // `queue` only.
    //
    // A slider drag produces changes far faster than a device that takes up to a
    // second to respond can consume them, so requests are coalesced: only the
    // newest target for a device is kept, and intermediate ones are dropped
    // rather than queued. Queuing them would leave the device visibly lagging
    // seconds behind the slider.
    private var pending: [String: (deviceID: AudioObjectID, db: Float)] = [:]
    private var draining: Set<String> = []

    private static func address(_ selector: AudioObjectPropertySelector)
        -> AudioObjectPropertyAddress
    {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: 0)
    }

    private static let gainSelector = kAudioDevicePropertyVolumeDecibels

    // MARK: - Discovery

    /// Whether this device has a usable gain stage, and what it can do.
    ///
    /// A device that reports the property but refuses to be written is worse
    /// than one that reports nothing, because the split would keep handing gain
    /// to a stage that never applies it. The settability check is therefore part
    /// of the capability test, not an afterthought.
    @discardableResult
    func discover(deviceUID: String, deviceID: AudioObjectID) -> HardwareGainRange? {
        var address = Self.address(Self.gainSelector)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
              settable.boolValue
        else { return nil }

        var rangeAddress = Self.address(kAudioDevicePropertyVolumeRangeDecibels)
        guard AudioObjectHasProperty(deviceID, &rangeAddress) else { return nil }
        var reported = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(
                deviceID, &rangeAddress, 0, nil, &size, &reported) == noErr,
              reported.mMaximum > reported.mMinimum,
              reported.mMinimum.isFinite, reported.mMaximum.isFinite
        else { return nil }

        // The step is not published anywhere. Both measured devices move in
        // whole decibels, and a 1 dB assumption is safe in a way a finer one is
        // not: if a device is actually finer, we lose a fraction of a decibel of
        // device gain to the DSP, which is inaudible. If we assumed finer than
        // the device is, every request would be silently rounded and the total
        // would sit permanently off by the rounding error.
        let range = HardwareGainRange(
            minDB: Float(reported.mMinimum), maxDB: Float(reported.mMaximum), stepDB: 1)

        capabilities[deviceUID] = (deviceID, range)
        installListener(deviceUID: deviceUID, deviceID: deviceID)
        return range
    }

    func capability(forDeviceUID uid: String) -> HardwareGainRange? {
        capabilities[uid]?.range
    }

    /// Forget a device. Called when it disappears, so a stale `AudioObjectID` is
    /// never written to — CoreAudio recycles IDs, and writing to a recycled one
    /// would change the gain of some unrelated device.
    func forget(deviceUID uid: String) {
        if let (deviceID, block) = listeners.removeValue(forKey: uid) {
            var address = Self.address(Self.gainSelector)
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, block)
        }
        capabilities.removeValue(forKey: uid)
        queue.async { [weak self] in
            self?.pending.removeValue(forKey: uid)
        }
    }

    func forgetAll() {
        for uid in Array(listeners.keys) { forget(deviceUID: uid) }
    }

    // MARK: - Reading

    /// The device's current gain, or `nil` if it cannot be read.
    ///
    /// Takes an ID rather than a UID so it is callable from any thread without
    /// touching main-thread state. Reading is usually fast but was measured as
    /// high as 206 ms, so it belongs on the background queue — never on a UI
    /// timer.
    static func reportedGain(deviceID: AudioObjectID) -> Float? {
        var address = address(gainSelector)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              value.isFinite
        else { return nil }
        return Float(value)
    }

    /// Reads the current gain in the background and reports it through
    /// `onReportedGainChanged`. Used at startup and after a reconnect to seed
    /// the compensation with the device's real value rather than an assumption.
    func refresh(deviceUID uid: String) {
        guard let capability = capabilities[uid] else { return }
        let deviceID = capability.deviceID
        queue.async { [weak self] in
            let value = Self.reportedGain(deviceID: deviceID)
            DispatchQueue.main.async { self?.onReportedGainChanged?(uid, value) }
        }
    }

    // MARK: - Writing

    /// Ask a device for a gain, eventually.
    ///
    /// Returns immediately. The caller must not assume the value has been
    /// applied when this returns — it hears about it through
    /// `onReportedGainChanged`, which is the only value the DSP compensation
    /// should ever be derived from.
    func request(gainDB: Float, forDeviceUID uid: String) {
        guard let capability = capabilities[uid] else { return }
        let target = capability.range.quantised(gainDB)
        let deviceID = capability.deviceID

        queue.async { [weak self] in
            guard let self else { return }
            self.pending[uid] = (deviceID, target)
            self.drain(uid: uid)
        }
    }

    /// Applies pending values until there are none left. A value that arrives
    /// while a slow write is in progress is picked up on the next pass; anything
    /// older than it has already been overwritten in `pending`.
    private func drain(uid: String) {
        guard !draining.contains(uid) else { return }
        draining.insert(uid)
        defer { draining.remove(uid) }

        while let request = pending.removeValue(forKey: uid) {
            var address = Self.address(Self.gainSelector)
            var value = Float32(request.db)
            let status = AudioObjectSetPropertyData(
                request.deviceID, &address, 0, nil,
                UInt32(MemoryLayout<Float32>.size), &value)

            // A failed write is not an error worth surfacing. The device may
            // have been unplugged mid-write, which is routine. Compensation
            // reads the device rather than trusting this, so a silent failure
            // degrades to "all the gain stays in the DSP" — a quieter noise
            // floor lost, and nothing else.
            let reported = status == noErr
                ? Self.reportedGain(deviceID: request.deviceID)
                : nil
            DispatchQueue.main.async { [weak self] in
                self?.onReportedGainChanged?(uid, reported)
            }
        }
    }

    // MARK: - External changes

    /// Notices the gain moving underneath us.
    ///
    /// Another application, Audio MIDI Setup, or a control on the device itself
    /// can all change this. Rather than fighting for ownership — polling and
    /// writing our value back, which becomes a tug of war the user can hear —
    /// the reported value is simply forwarded, and the DSP absorbs the
    /// difference so the total the user set is preserved.
    private func installListener(deviceUID uid: String, deviceID: AudioObjectID) {
        guard listeners[uid] == nil else { return }
        var address = Self.address(Self.gainSelector)

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            let value = Self.reportedGain(deviceID: deviceID)
            DispatchQueue.main.async { self?.onReportedGainChanged?(uid, value) }
        }

        guard AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block) == noErr
        else { return }
        listeners[uid] = (deviceID, block)
    }
}
