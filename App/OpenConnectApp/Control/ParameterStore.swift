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

    /// Live meter values, refreshed on a timer.
    @Published private(set) var meters: [String: ChannelMeters] = [:]

    @Published private(set) var diagnostics = EngineDiagnostics()

    /// Every physical input attached to the machine, whether or not it is in use.
    @Published private(set) var availableDevices: [AudioInputDevice] = []
    /// The subset the user wants OpenConnect to mix. Empty is a valid choice.
    @Published private(set) var enabledDeviceUIDs: Set<String> = []
    /// True until the user has made an explicit choice, in which case every
    /// input is used so a first launch is not silent.
    @Published private(set) var deviceSelectionIsImplicit = true

    /// Set when the user has not granted microphone access yet.
    @Published var microphonePermissionDenied = false

    private let store = SettingsStore()
    private var saved: [String: ChannelSettings]
    private weak var engine: AudioEngine?
    private var meterTimer: Timer?
    private var saveWorkItem: DispatchWorkItem?
    private let soakStart = Date()
    private var lastSoakLog: Date?

    init() {
        saved = store.load()
    }

    func attach(engine: AudioEngine) {
        self.engine = engine
        engine.onDevicesChanged = { [weak self] devices in
            Task { @MainActor in self?.reconcile(devices: devices) }
        }
        engine.onAvailableDevicesChanged = { [weak self] devices in
            Task { @MainActor in self?.refreshAvailableDevices(devices) }
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
            // No explicit choice yet: everything is in use, and the UI reflects
            // that by showing all boxes ticked.
            deviceSelectionIsImplicit = true
            enabledDeviceUIDs = Set(devices.map(\.uid))
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
        for (index, settings) in channels.enumerated() {
            pushAll(channel: index, settings: settings)
        }
        persist()
    }

    // MARK: - Mutation

    /// Applies an edit to one channel, persists it, and forwards only the fields
    /// that actually changed to the render thread.
    func update(_ uid: String, _ mutate: (inout ChannelSettings) -> Void) {
        guard let index = channels.firstIndex(where: { $0.deviceUID == uid }) else { return }
        let before = channels[index]
        var after = before
        mutate(&after)
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
        send(.gainDB, channel: channel, s.gainDB)
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

        send(.bigBottomEnabled, channel: channel, s.bigBottomEnabled ? 1 : 0)
        send(.bigBottomAmount, channel: channel, s.bigBottom.amount)
        send(.bigBottomFrequency, channel: channel, s.bigBottom.frequency)
        send(.bigBottomDrive, channel: channel, s.bigBottom.drive)

        send(.faderDB, channel: channel, s.faderDB)
        send(.effectivelyMuted, channel: channel, isEffectivelyMuted(s) ? 1 : 0)
    }

    private func pushChanged(channel c: Int, from a: ChannelSettings, to b: ChannelSettings) {
        if a.gainDB != b.gainDB { send(.gainDB, channel: c, b.gainDB) }
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

        if a.bigBottomEnabled != b.bigBottomEnabled { send(.bigBottomEnabled, channel: c, b.bigBottomEnabled ? 1 : 0) }
        if a.bigBottom.amount != b.bigBottom.amount { send(.bigBottomAmount, channel: c, b.bigBottom.amount) }
        if a.bigBottom.frequency != b.bigBottom.frequency { send(.bigBottomFrequency, channel: c, b.bigBottom.frequency) }
        if a.bigBottom.drive != b.bigBottom.drive { send(.bigBottomDrive, channel: c, b.bigBottom.drive) }

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

    private func startMeterPolling() {
        meterTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMeters() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func pollMeters() {
        guard let engine else { return }
        var next: [String: ChannelMeters] = [:]
        for (index, settings) in channels.enumerated() {
            next[settings.deviceUID] = engine.meters(forChannel: index)
        }
        // `@Published` fires on every assignment, equal or not, which would
        // redraw every meter 30 times a second even in silence. Only publish on
        // an actual change so an idle app costs nothing.
        if next != meters {
            meters = next
        }
        let updated = engine.diagnostics()
        if updated != diagnostics {
            diagnostics = updated
        }
        logSoakSampleIfEnabled(updated)
    }

    // MARK: - Soak logging
    //
    // Opt-in via OPENCONNECT_SOAK_LOG=<seconds>. Off by default and costing one
    // comparison per poll when off, this is how a long two-microphone run is
    // measured: xruns must stay at zero and each channel's ring fill must stay
    // bounded around its target rather than walking towards either end.

    private func logSoakSampleIfEnabled(_ d: EngineDiagnostics) {
        guard let interval = Self.soakInterval else { return }
        let now = Date()
        if let last = lastSoakLog, now.timeIntervalSince(last) < interval { return }
        lastSoakLog = now

        let elapsed = Int(now.timeIntervalSince(soakStart))
        var parts = ["t=\(elapsed)s",
                     "under=\(d.underruns)",
                     "over=\(d.overruns)",
                     "dropped=\(d.droppedParameters)"]
        for uid in d.perChannelRatioPPM.keys.sorted() {
            let name = d.perChannelName[uid] ?? uid
            let ppm = d.perChannelRatioPPM[uid] ?? 0
            let fill = d.perChannelFill[uid] ?? 0
            parts.append(String(format: "[%@ ppm=%+.1f fill=%.1f]", name, ppm, fill))
        }
        NSLog("OpenConnect SOAK %@", parts.joined(separator: " "))
    }

    private static let soakInterval: TimeInterval? = {
        guard let raw = ProcessInfo.processInfo.environment["OPENCONNECT_SOAK_LOG"],
              let seconds = Double(raw), seconds > 0 else { return nil }
        return seconds
    }()

    deinit {
        meterTimer?.invalidate()
    }
}
