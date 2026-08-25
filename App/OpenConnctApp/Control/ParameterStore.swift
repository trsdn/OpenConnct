import Combine
import Foundation

/// The single UI-facing source of truth.
///
/// Owns the user's settings, persists them, and forwards every change to the
/// audio engine through a lock-free queue. The UI never touches the engine
/// directly and the engine never touches SwiftUI.
@MainActor
final class ParameterStore: ObservableObject {
    /// Channels in mixer order. Index into this array is the channel index used
    /// on the render thread.
    @Published private(set) var channels: [ChannelSettings] = []

    /// Live meters and engine counters. These tick 30 times a second, so they
    /// are deliberately kept off this object — see `MeterHub` for why.
    let meterHub = MeterHub()

    /// Every physical input attached to the machine, whether or not it is in use.
    @Published private(set) var availableDevices: [AudioInputDevice] = []
    /// The subset the user wants OpenConnct to mix. Empty is a valid choice.
    @Published private(set) var enabledDeviceUIDs: Set<String> = []
    /// True until the user has made an explicit choice, in which case every
    /// input is used so a first launch is not silent.
    @Published private(set) var deviceSelectionIsImplicit = true

    /// Set when the user has not granted microphone access yet.
    @Published var microphonePermissionDenied = false

    /// Which devices have a gain stage of their own, and what it can do. Read by
    /// the UI to show that gain is coming from the microphone rather than the
    /// DSP; empty for every device that has none, which is most of them.
    @Published private(set) var hardwareGainRanges: [String: HardwareGainRange] = [:]

    /// What each device most recently *reported*, which is not the same as what
    /// it was last asked for — see `applyGain` for why that distinction is the
    /// whole point.
    private var reportedHardwareGain: [String: Float] = [:]

    /// What each microphone reports about the switches on its own body.
    ///
    /// Absent for every device that has no control channel, which is most of
    /// them, and absent until a device has answered. Absent means "cannot be
    /// asked", and the interface hedges accordingly rather than claiming the
    /// switches are off.
    @Published private(set) var bodySwitches: [String: MicBodySwitches] = [:]

    /// Which audio device each USB identity belongs to. Kept so that a reading
    /// arriving from the HID side can be attributed to a channel without
    /// searching, and so that a device unplugged on one bus clears its state on
    /// the other.
    private var deviceUIDsByUSBIdentity: [USBDeviceIdentity: String] = [:]

    private let hardwareGain = CoreAudioInputGain()
    private let micControl = MicControlChannel()

    private let store = SettingsStore()
    private var saved: [String: ChannelSettings]
    private weak var engine: AudioEngine?
    private var meterTimer: Timer?
    private var saveWorkItem: DispatchWorkItem?
    private let soakStart = Date()
    private var lastSoakLog: Date?
    private var soakAccumulators: [String: SoakAccumulator] = [:]
    private var diagnosticsTick = 0

    init() {
        saved = store.load()
        hardwareGain.onReportedGainChanged = { [weak self] uid, db in
            Task { @MainActor in self?.hardwareGainDidChange(uid: uid, db: db) }
        }
        micControl.onSwitchesChanged = { [weak self] identity, switches in
            Task { @MainActor in self?.bodySwitchesDidChange(identity, switches) }
        }
        micControl.onDeviceLost = { [weak self] identity in
            Task { @MainActor in self?.bodySwitchesDeviceLost(identity) }
        }
        micControl.start()
    }

    func attach(engine: AudioEngine) {
        self.engine = engine
        engine.onDevicesChanged = { [weak self] devices in
            Task { @MainActor in self?.reconcile(devices: devices) }
        }
        engine.onAvailableDevicesChanged = { [weak self] devices in
            Task { @MainActor in self?.refreshAvailableDevices(devices) }
        }
        engine.onSinkAvailabilityChanged = { _ in
            // The driver appearing or vanishing is the one event that can make
            // the install banner's answer go stale while the app is frontmost —
            // and it is exactly when the user is looking, because the mixer has
            // just started saying "No device". Relying on the app being
            // deactivated and reactivated meant the explanation only showed up
            // after the user had already gone looking elsewhere for it.
            //
            // A notification rather than a direct call: the engine has no
            // business knowing that an installer exists, and the banner lives
            // several layers away in the view tree.
            Task { @MainActor in
                NotificationCenter.default.post(name: .ocSinkAvailabilityChanged, object: nil)
            }
        }
        startMeterPolling()
    }

    // MARK: - Device selection

    private func refreshAvailableDevices(_ devices: [AudioInputDevice]) {
        availableDevices = devices
        if let stored = engine?.enabledDeviceUIDs {
            deviceSelectionIsImplicit = false
            enabledDeviceUIDs = stored
        } else {
            // No explicit choice yet. Default to every input *except* the
            // built-in microphone, provided something else is available —
            // plugging in a microphone is a statement of intent, and quietly
            // mixing the laptop's own microphone in alongside it adds room
            // noise that nobody asked for and few would think to look for.
            //
            // If the built-in is all there is, use it: an app with no inputs
            // at all would be worse than one with a mediocre input.
            // Mirror the engine's default so the tick boxes show what is
            // actually in use. Deliberately *not* persisted: writing it back
            // would turn a default into an apparent user choice.
            deviceSelectionIsImplicit = true
            let external = devices.filter { !$0.isBuiltIn }
            enabledDeviceUIDs = Set((external.isEmpty ? devices : external).map(\.uid))
        }
    }

    /// Turns one input on or off. The first call also converts the implicit
    /// "use everything" state into an explicit, persisted selection.
    func setDevice(_ uid: String, enabled: Bool) {
        var next = enabledDeviceUIDs
        if enabled { next.insert(uid) } else { next.remove(uid) }
        guard next != enabledDeviceUIDs else { return }
        enabledDeviceUIDs = next
        deviceSelectionIsImplicit = false
        engine?.setEnabledDeviceUIDs(next)
    }

    // MARK: - Device reconciliation

    /// Rebuilds the channel list from the currently connected input devices,
    /// restoring persisted settings for any device we have seen before.
    func reconcile(devices: [AudioInputDevice]) {
        var next: [ChannelSettings] = []
        for device in devices {
            if var existing = saved[device.uid] {
                // The user may have renamed the device in Audio MIDI Setup.
                existing.deviceName = device.name
                next.append(existing)
            } else {
                next.append(ChannelSettings(deviceUID: device.uid, deviceName: device.name))
            }
        }
        channels = next
        meterHub.ensure(uids: next.map(\.deviceUID))
        reconcileHardwareGain(devices: devices)
        reconcileBodySwitches(devices: devices)
        for (index, settings) in channels.enumerated() {
            pushAll(channel: index, settings: settings)
        }
        persist()
    }

    // MARK: - Switches on the microphone body

    /// Keeps the audio-device view of the world and the USB view of it in step.
    ///
    /// The two buses discover and lose devices independently and in either
    /// order, so neither side may assume the other has caught up. This is the
    /// one place that reconciles them, and it errs towards forgetting: a reading
    /// attributed to a device that is no longer here would be shown against
    /// whatever took its place.
    private func reconcileBodySwitches(devices: [AudioInputDevice]) {
        let present = Set(devices.map(\.uid))
        for (identity, uid) in deviceUIDsByUSBIdentity where !present.contains(uid) {
            deviceUIDsByUSBIdentity.removeValue(forKey: identity)
        }
        for uid in bodySwitches.keys where !present.contains(uid) {
            bodySwitches.removeValue(forKey: uid)
        }
        for device in devices {
            guard let identity = device.usbIdentity else { continue }
            deviceUIDsByUSBIdentity[identity] = device.uid
        }
    }

    /// A microphone has reported its own switch positions.
    ///
    /// Arrives on the main queue, at most a few times a second, and only when
    /// something actually moved. A reading for a device this app is not mixing
    /// is kept anyway: the user may enable that device a moment later, and
    /// having the answer already is better than showing a hedge until the next
    /// poll comes round.
    private func bodySwitchesDidChange(
        _ identity: USBDeviceIdentity, _ switches: MicBodySwitches
    ) {
        guard let uid = deviceUIDsByUSBIdentity[identity] else { return }
        guard bodySwitches[uid] != switches else { return }
        bodySwitches[uid] = switches
    }

    /// A microphone with a control channel has been unplugged.
    ///
    /// Its last reported state is dropped rather than kept. Stale switch
    /// positions are worse than none: the interface would state as fact
    /// something about hardware that is no longer attached.
    private func bodySwitchesDeviceLost(_ identity: USBDeviceIdentity) {
        guard let uid = deviceUIDsByUSBIdentity.removeValue(forKey: identity) else { return }
        bodySwitches.removeValue(forKey: uid)
    }

    // MARK: - Hardware gain

    /// Finds out which of the attached devices can set their own input gain, and
    /// drops any that have gone away.
    ///
    /// Gain applied inside the microphone happens before its converter, so it
    /// lifts the signal above the converter's own noise rather than amplifying
    /// that noise along with it. Measured on real hardware the benefit is real
    /// but modest — around 2.5 dB of noise floor at a typical setting, and
    /// swamped by room noise at extreme ones. Worth taking because it is free;
    /// not worth claiming as transformative.
    private func reconcileHardwareGain(devices: [AudioInputDevice]) {
        let present = Set(devices.map(\.uid))
        for uid in hardwareGainRanges.keys where !present.contains(uid) {
            hardwareGain.forget(deviceUID: uid)
            hardwareGainRanges.removeValue(forKey: uid)
            reportedHardwareGain.removeValue(forKey: uid)
        }

        for device in devices where hardwareGainRanges[device.uid] == nil {
            guard let range = hardwareGain.discover(
                deviceUID: device.uid, deviceID: device.objectID)
            else { continue }
            hardwareGainRanges[device.uid] = range
            // Seed from the device rather than assuming it starts where we left
            // it. Another application may have moved it while we were not
            // running, and the compensation must be right from the first block.
            hardwareGain.refresh(deviceUID: device.uid)
        }
    }

    /// Whether this channel is allowed to *move* the device's gain stage.
    ///
    /// Note what this does not gate: the compensation below always accounts for
    /// whatever the device reports, switch or no switch. The device's gain is
    /// part of the signal path whether this app put it there or not, so ignoring
    /// it would make the user's number mean two different things depending on a
    /// preference. Switching off freezes the device where it stands and leaves
    /// the DSP holding the difference — inaudible, which is what a preference
    /// about side effects should be.
    private func mayWriteHardwareGain(_ settings: ChannelSettings) -> Bool {
        settings.hardwareGainEnabled && hardwareGainRanges[settings.deviceUID] != nil
    }

    /// The gain the DSP must apply for this channel.
    ///
    /// Derived from what the device *reports*, never from what it was asked for.
    /// Writing the property was measured taking up to a second, so between the
    /// request and its effect there is a long window in which the two disagree;
    /// compensating against the reported value means the total the user set is
    /// correct at every instant during that window, instead of dipping or
    /// spiking until the device catches up.
    private func softwareGainDB(for settings: ChannelSettings) -> Float {
        guard hardwareGainRanges[settings.deviceUID] != nil else { return settings.gainDB }
        return HardwareGainSplitter.compensate(
            totalDB: settings.gainDB,
            hardwareDB: reportedHardwareGain[settings.deviceUID]
        ).softwareDB
    }

    /// The usable total gain for a channel.
    ///
    /// With a microphone that has its own preamp the number covers that preamp
    /// as well as the DSP trim, so the ceiling has to leave room above what the
    /// device alone can reach — otherwise adopting a device already near its
    /// maximum would land outside the slider. Defined here rather than in the
    /// view because the guided calibration has to clamp to exactly the same
    /// range, and two copies of it would eventually disagree.
    func gainRange(for uid: String) -> ClosedRange<Float> {
        guard let hw = hardwareGainRanges[uid] else { return -20...40 }
        return -20...max(40, hw.maxDB + 10)
    }

    /// One reading for the guided gain calibration.
    struct CalibrationSample {
        /// The signal as the device delivered it, before our gain and pad. Only
        /// used to tell an overloaded microphone apart from our own gain being
        /// too high.
        var rawPeakDB: Float
        /// After gain and pad, before the effects and the fader. This is the
        /// tap the meter's target band actually describes, and it is the only
        /// one where the arithmetic is linear in the gain — the tap after the
        /// effects has a compressor in it, and the tap after the fader would
        /// demand +60 dB of gain to compensate for a fader pulled down.
        ///
        /// Being before the fader also means the measurement works on a muted
        /// channel, which matters: a device the app has never seen arrives
        /// muted, and that is exactly the moment to calibrate it.
        var postGainPeakDB: Float
        var gainDB: Float
    }

    func calibrationSample(for uid: String) -> CalibrationSample? {
        guard let index = channels.firstIndex(where: { $0.deviceUID == uid }) else { return nil }
        let settings = channels[index]
        let m = meterSnapshot(for: uid)
        guard m.connected else { return nil }
        let pad = settings.padEnabled ? settings.padDB : 0
        return CalibrationSample(
            rawPeakDB: m.inputPeakDB,
            postGainPeakDB: m.inputPeakDB + pad + softwareGainDB(for: settings),
            gainDB: settings.gainDB)
    }

    /// Sends the DSP half of the gain and, when allowed, asks the device for its    /// half. Never blocks: the request is queued and coalesced, and the result
    /// arrives through `hardwareGainDidChange`.
    private func applyGain(channel: Int, settings: ChannelSettings) {
        send(.gainDB, channel: channel, softwareGainDB(for: settings))
        guard mayWriteHardwareGain(settings),
              let range = hardwareGainRanges[settings.deviceUID]
        else {
            // Deliberately no write at all. An earlier version drove the device
            // to the bottom of its range here, on the theory that "off" should
            // mean "contributing nothing". Measured on real hardware that made
            // the microphone almost deaf — this range is the microphone's
            // preamp, and at its minimum a room sits near −100 dBFS. "Off" has
            // to mean "don't touch it", not "turn it down".
            return
        }
        hardwareGain.request(
            gainDB: range.quantised(settings.gainDB), forDeviceUID: settings.deviceUID)
    }

    /// The device's gain moved. Re-derive the DSP half so the total stays put.
    ///
    /// This is also what makes an external change inaudible: if another
    /// application or a control on the device moves the gain, the same
    /// arithmetic absorbs it and the user hears nothing.
    private func hardwareGainDidChange(uid: String, db: Float?) {
        guard let index = channels.firstIndex(where: { $0.deviceUID == uid }) else {
            reportedHardwareGain[uid] = db
            return
        }

        // First sight of this device: fold its current gain into the user's
        // number so the meaning of an already-saved value does not change and
        // nothing sounds different after the update. Done here rather than at
        // discovery because the device's value only arrives asynchronously.
        if let db, !channels[index].hardwareGainAdopted {
            reportedHardwareGain[uid] = db
            var adopted = channels[index]
            adopted.gainDB = HardwareGainSplitter.adoptedTotal(
                previousTotalDB: adopted.gainDB, reportedHardwareDB: db)
            adopted.hardwareGainAdopted = true
            channels[index] = adopted
            applyGain(channel: index, settings: adopted)
            persist()
            return
        }

        guard reportedHardwareGain[uid] != db else { return }
        reportedHardwareGain[uid] = db
        send(.gainDB, channel: index, softwareGainDB(for: channels[index]))
    }

    // MARK: - Mutation

    /// Applies an edit to one channel, persists it, and forwards only the fields
    /// that actually changed to the render thread.
    func update(_ uid: String, _ mutate: (inout ChannelSettings) -> Void) {
        guard let index = channels.firstIndex(where: { $0.deviceUID == uid }) else { return }
        let before = channels[index]
        var after = before
        mutate(&after)
        // Any deliberate change to mute retires the explanation for an automatic
        // one. Checked on mute alone rather than on any edit: adjusting a
        // channel's gain is not an answer to "why is this silent", so the note
        // should survive that.
        if after.muted != before.muted { after.arrivedMuted = false }
        guard after != before else { return }
        channels[index] = after
        pushChanged(channel: index, from: before, to: after)

        // Solo is a cross-channel concept, so recompute effective mute for
        // everyone whenever mute or solo moves.
        if before.muted != after.muted || before.soloed != after.soloed {
            pushEffectiveMutes()
        }
        persist()
    }

    /// True when any channel is soloed, in which case non-soloed channels are silent.
    var soloActive: Bool { channels.contains { $0.soloed } }

    func isEffectivelyMuted(_ settings: ChannelSettings) -> Bool {
        if settings.muted { return true }
        if soloActive && !settings.soloed { return true }
        return false
    }

    private func pushEffectiveMutes() {
        for (index, settings) in channels.enumerated() {
            send(.effectivelyMuted, channel: index, isEffectivelyMuted(settings) ? 1 : 0)
        }
    }

    // MARK: - Parameter transport

    private func send(_ param: OCParam, channel: Int, _ value: Float) {
        engine?.setParameter(param.packed(channel: channel), value)
    }

    private func pushAll(channel: Int, settings s: ChannelSettings) {
        applyGain(channel: channel, settings: s)
        send(.padDB, channel: channel, s.padDB)
        send(.padEnabled, channel: channel, s.padEnabled ? 1 : 0)
        send(.hpfMode, channel: channel, Float(s.hpfMode.rawValue))
        send(.hpfFrequency, channel: channel, s.hpfFrequency)

        send(.gateEnabled, channel: channel, s.gateEnabled ? 1 : 0)
        send(.gateThresholdDB, channel: channel, s.gate.thresholdDB)
        send(.gateAttackMS, channel: channel, s.gate.attackMS)
        send(.gateHoldMS, channel: channel, s.gate.holdMS)
        send(.gateReleaseMS, channel: channel, s.gate.releaseMS)
        send(.gateHysteresisDB, channel: channel, s.gate.hysteresisDB)
        send(.gateRangeDB, channel: channel, s.gate.rangeDB)

        send(.compressorEnabled, channel: channel, s.compressorEnabled ? 1 : 0)
        send(.compThresholdDB, channel: channel, s.compressor.thresholdDB)
        send(.compRatio, channel: channel, s.compressor.ratio)
        send(.compAttackMS, channel: channel, s.compressor.attackMS)
        send(.compReleaseMS, channel: channel, s.compressor.releaseMS)
        send(.compMakeupDB, channel: channel, s.compressor.makeupDB)
        send(.compKneeDB, channel: channel, s.compressor.kneeDB)

        send(.exciterEnabled, channel: channel, s.exciterEnabled ? 1 : 0)
        send(.exciterAmount, channel: channel, s.exciter.amount)
        send(.exciterFrequency, channel: channel, s.exciter.frequency)
        send(.exciterDrive, channel: channel, s.exciter.drive)

        send(.bassEnhancerEnabled, channel: channel, s.bassEnhancerEnabled ? 1 : 0)
        send(.bassEnhancerAmount, channel: channel, s.bassEnhancer.amount)
        send(.bassEnhancerFrequency, channel: channel, s.bassEnhancer.frequency)
        send(.bassEnhancerDrive, channel: channel, s.bassEnhancer.drive)

        send(.faderDB, channel: channel, s.faderDB)
        send(.effectivelyMuted, channel: channel, isEffectivelyMuted(s) ? 1 : 0)
    }

    private func pushChanged(channel c: Int, from a: ChannelSettings, to b: ChannelSettings) {
        if a.gainDB != b.gainDB || a.hardwareGainEnabled != b.hardwareGainEnabled {
            applyGain(channel: c, settings: b)
        }
        if a.padDB != b.padDB { send(.padDB, channel: c, b.padDB) }
        if a.padEnabled != b.padEnabled { send(.padEnabled, channel: c, b.padEnabled ? 1 : 0) }
        if a.hpfMode != b.hpfMode { send(.hpfMode, channel: c, Float(b.hpfMode.rawValue)) }
        if a.hpfFrequency != b.hpfFrequency { send(.hpfFrequency, channel: c, b.hpfFrequency) }

        if a.gateEnabled != b.gateEnabled { send(.gateEnabled, channel: c, b.gateEnabled ? 1 : 0) }
        if a.gate.thresholdDB != b.gate.thresholdDB { send(.gateThresholdDB, channel: c, b.gate.thresholdDB) }
        if a.gate.attackMS != b.gate.attackMS { send(.gateAttackMS, channel: c, b.gate.attackMS) }
        if a.gate.holdMS != b.gate.holdMS { send(.gateHoldMS, channel: c, b.gate.holdMS) }
        if a.gate.releaseMS != b.gate.releaseMS { send(.gateReleaseMS, channel: c, b.gate.releaseMS) }
        if a.gate.hysteresisDB != b.gate.hysteresisDB { send(.gateHysteresisDB, channel: c, b.gate.hysteresisDB) }
        if a.gate.rangeDB != b.gate.rangeDB { send(.gateRangeDB, channel: c, b.gate.rangeDB) }

        if a.compressorEnabled != b.compressorEnabled { send(.compressorEnabled, channel: c, b.compressorEnabled ? 1 : 0) }
        if a.compressor.thresholdDB != b.compressor.thresholdDB { send(.compThresholdDB, channel: c, b.compressor.thresholdDB) }
        if a.compressor.ratio != b.compressor.ratio { send(.compRatio, channel: c, b.compressor.ratio) }
        if a.compressor.attackMS != b.compressor.attackMS { send(.compAttackMS, channel: c, b.compressor.attackMS) }
        if a.compressor.releaseMS != b.compressor.releaseMS { send(.compReleaseMS, channel: c, b.compressor.releaseMS) }
        if a.compressor.makeupDB != b.compressor.makeupDB { send(.compMakeupDB, channel: c, b.compressor.makeupDB) }
        if a.compressor.kneeDB != b.compressor.kneeDB { send(.compKneeDB, channel: c, b.compressor.kneeDB) }

        if a.exciterEnabled != b.exciterEnabled { send(.exciterEnabled, channel: c, b.exciterEnabled ? 1 : 0) }
        if a.exciter.amount != b.exciter.amount { send(.exciterAmount, channel: c, b.exciter.amount) }
        if a.exciter.frequency != b.exciter.frequency { send(.exciterFrequency, channel: c, b.exciter.frequency) }
        if a.exciter.drive != b.exciter.drive { send(.exciterDrive, channel: c, b.exciter.drive) }

        if a.bassEnhancerEnabled != b.bassEnhancerEnabled { send(.bassEnhancerEnabled, channel: c, b.bassEnhancerEnabled ? 1 : 0) }
        if a.bassEnhancer.amount != b.bassEnhancer.amount { send(.bassEnhancerAmount, channel: c, b.bassEnhancer.amount) }
        if a.bassEnhancer.frequency != b.bassEnhancer.frequency { send(.bassEnhancerFrequency, channel: c, b.bassEnhancer.frequency) }
        if a.bassEnhancer.drive != b.bassEnhancer.drive { send(.bassEnhancerDrive, channel: c, b.bassEnhancer.drive) }

        if a.faderDB != b.faderDB { send(.faderDB, channel: c, b.faderDB) }
    }

    // MARK: - Persistence

    private func persist() {
        for settings in channels {
            saved[settings.deviceUID] = settings
        }
        // Coalesce rapid edits (dragging a fader) into one write.
        saveWorkItem?.cancel()
        let snapshot = saved
        let item = DispatchWorkItem { [store] in store.save(snapshot) }
        saveWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    // MARK: - Meters

    /// Meter refresh rate in Hz. Overridable with OPENCONNCT_METER_HZ, which
    /// exists so the UI's cost can be measured by ablation rather than guessed
    /// at: run once at the default and once at 0 and the difference is what the
    /// meters cost. 0 disables metering entirely, leaving audio untouched.
    ///
    /// The default is 20 rather than 30 because the cost is linear in the rate
    /// — measured 2.2% at 5 Hz, 5.8% at 15 Hz, 12.5% at 30 Hz — while 20 Hz is
    /// still fast enough that a peak-holding meter reads the same to the eye.
    /// That is a trade, not a fix: the real cost is SwiftUI's per-update
    /// overhead, and the audio engine underneath it measures 0.5%.
    static let meterHz: Double = {
        guard let raw = ProcessInfo.processInfo.environment["OPENCONNCT_METER_HZ"],
              let hz = Double(raw), hz >= 0 else { return 20 }
        return hz
    }()

    private func startMeterPolling() {
        meterTimer?.invalidate()
        guard Self.meterHz > 0 else { return }
        let timer = Timer(timeInterval: 1.0 / Self.meterHz, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMeters() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    /// Current levels for one channel, read straight from the engine's atomics.
    /// Called from the meter views' timeline, so it must stay allocation-free
    /// and must not publish anything.
    func meterSnapshot(for uid: String) -> ChannelMeters {
        guard let engine, let index = channels.firstIndex(where: { $0.deviceUID == uid })
        else { return ChannelMeters() }
        return engine.meters(forChannel: index)
    }

    private func pollMeters() {
        guard let engine else { return }
        for (index, settings) in channels.enumerated() {
            let m = engine.meters(forChannel: index)
            meterHub.publishMeters(m, for: settings.deviceUID)
            // Connection state is pushed separately because it changes about
            // twice a day and must not drag the microphone icon, an SF Symbol,
            // into the meter's redraw.
            meterHub.publishConnection(m.connected, for: settings.deviceUID)
        }

        meterHub.master.publish(engine.masterMeters())

        // Diagnostics are sampled at the full rate, because the soak statistics
        // want as many observations of the ring fill as they can get, but they
        // are only published to the UI a few times a second. The status line
        // reads "Ready" for hours at a time; redrawing it and its counters 30
        // times a second buys nothing and is not free.
        let updated = engine.diagnostics()
        logSoakSampleIfEnabled(updated)

        diagnosticsTick += 1
        if diagnosticsTick >= Self.diagnosticsDivider {
            diagnosticsTick = 0
            meterHub.diagnostics.publish(updated)
        }
    }

    /// Publish diagnostics at roughly 2 Hz regardless of the meter rate.
    private static let diagnosticsDivider = max(1, Int((meterHz / 2).rounded()))

    // MARK: - Soak logging
    //
    // Opt-in via OPENCONNCT_SOAK_LOG=<seconds>. Off by default and costing one
    // comparison per poll when off, this is how a long two-microphone run is
    // measured: xruns must stay at zero and each channel's ring fill must stay
    // bounded around its target rather than walking towards either end.
    //
    // The figures are accumulated over every 30 Hz poll and reported as
    // min/mean/max, not sampled once per interval. An instantaneous reading is
    // worthless here: the ring fill ripples as the input and output callbacks
    // drift in and out of phase, so a single sample every 15 s aliases that
    // ripple and can make a perfectly stable controller look like it is
    // oscillating by hundreds of ppm.

    private struct SoakAccumulator {
        var fillMin = Double.greatestFiniteMagnitude
        var fillMax = -Double.greatestFiniteMagnitude
        var fillSum = 0.0
        var ppmMin = Double.greatestFiniteMagnitude
        var ppmMax = -Double.greatestFiniteMagnitude
        var ppmSum = 0.0
        var count = 0
        var maxGapUS: UInt32 = 0

        mutating func add(fill: Double, ppm: Double, gapUS: UInt32) {
            maxGapUS = max(maxGapUS, gapUS)
            fillMin = min(fillMin, fill)
            fillMax = max(fillMax, fill)
            fillSum += fill
            ppmMin = min(ppmMin, ppm)
            ppmMax = max(ppmMax, ppm)
            ppmSum += ppm
            count += 1
        }

        var summary: String {
            guard count > 0 else { return "no samples" }
            let n = Double(count)
            return String(
                format: "fill %.0f/%.1f/%.0f ppm %+.1f/%+.1f/%+.1f gap %.1fms",
                fillMin, fillSum / n, fillMax,
                ppmMin, ppmSum / n, ppmMax,
                Double(maxGapUS) / 1000.0)
        }
    }

    private func logSoakSampleIfEnabled(_ d: EngineDiagnostics) {
        guard let interval = Self.soakInterval else { return }

        for (uid, ppm) in d.perChannelRatioPPM {
            soakAccumulators[uid, default: SoakAccumulator()]
                .add(fill: d.perChannelFill[uid] ?? 0, ppm: ppm,
                     gapUS: d.perChannelMaxInputGapUS[uid] ?? 0)
        }

        let now = Date()
        if let last = lastSoakLog, now.timeIntervalSince(last) < interval { return }
        lastSoakLog = now

        let elapsed = Int(now.timeIntervalSince(soakStart))
        var parts = ["t=\(elapsed)s",
                     "under=\(d.underruns)",
                     "over=\(d.overruns)",
                     "dropped=\(d.droppedParameters)"]
        for uid in soakAccumulators.keys.sorted() {
            let name = d.perChannelName[uid] ?? uid
            parts.append("[\(name) \(soakAccumulators[uid]!.summary)]")
        }
        soakAccumulators.removeAll(keepingCapacity: true)
        NSLog("OpenConnct SOAK %@", parts.joined(separator: " "))
    }

    private static let soakInterval: TimeInterval? = {
        guard let raw = ProcessInfo.processInfo.environment["OPENCONNCT_SOAK_LOG"],
              let seconds = Double(raw), seconds > 0 else { return nil }
        return seconds
    }()

    deinit {
        meterTimer?.invalidate()
    }
}

extension Notification.Name {
    /// Posted when the virtual output device appears or disappears, so anything
    /// whose advice depends on the driver being installed can re-read the disk.
    static let ocSinkAvailabilityChanged = Notification.Name("audio.openconnct.sinkAvailabilityChanged")
}
