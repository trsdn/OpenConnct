import Foundation

/// High-pass filter mode. Mirrors `oc_hpf_mode` in the DSP core.
enum HPFMode: Int, Codable, CaseIterable, Identifiable {
    case off = 0
    case hz75 = 1
    case hz150 = 2
    case continuous = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .hz75: return "75 Hz"
        case .hz150: return "150 Hz"
        case .continuous: return "Variable"
        }
    }
}

struct GateSettings: Codable, Equatable {
    var thresholdDB: Float = -45
    var attackMS: Float = 2
    var holdMS: Float = 100
    var releaseMS: Float = 200
    var hysteresisDB: Float = 6
    /// How far the gate attenuates when closed. Full mute makes the room
    /// disappear abruptly; a finite range ducks it instead, which sounds
    /// natural on a noisy input.
    var rangeDB: Float = -60

    private enum CodingKeys: String, CodingKey {
        case thresholdDB, attackMS, holdMS, releaseMS, hysteresisDB, rangeDB
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thresholdDB = try c.decodeIfPresent(Float.self, forKey: .thresholdDB) ?? -45
        attackMS = try c.decodeIfPresent(Float.self, forKey: .attackMS) ?? 2
        holdMS = try c.decodeIfPresent(Float.self, forKey: .holdMS) ?? 100
        releaseMS = try c.decodeIfPresent(Float.self, forKey: .releaseMS) ?? 200
        hysteresisDB = try c.decodeIfPresent(Float.self, forKey: .hysteresisDB) ?? 6
        rangeDB = try c.decodeIfPresent(Float.self, forKey: .rangeDB) ?? -60
    }
}

struct CompressorSettings: Codable, Equatable {
    var thresholdDB: Float = -18
    var ratio: Float = 3
    var attackMS: Float = 10
    var releaseMS: Float = 120
    var makeupDB: Float = 0
    var kneeDB: Float = 6
}

struct ExciterSettings: Codable, Equatable {
    var amount: Float = 0.35
    var frequency: Float = 3500
    var drive: Float = 0.5
}

struct BassEnhancerSettings: Codable, Equatable {
    var amount: Float = 0.35
    var frequency: Float = 100
    var drive: Float = 0.5
}

/// Everything the user can configure for one microphone.
///
/// Persisted per hardware device UID so that unplugging and replugging a mic
/// restores its settings exactly.
struct ChannelSettings: Codable, Equatable, Identifiable {
    var deviceUID: String
    var deviceName: String

    var gainDB: Float = 0
    /// Whether the microphone's own gain stage may take part of `gainDB`.
    ///
    /// On by default because it is measurably (if modestly) quieter, and off is
    /// available because writing to a device is a side effect outside this app:
    /// it persists in the device, and other software sees it. Anyone who wants
    /// this app to leave their hardware alone must be able to say so.
    var hardwareGainEnabled: Bool = true
    /// Whether `gainDB` has been converted to an absolute total.
    ///
    /// Before hardware gain existed, `gainDB` was a DSP trim sitting on top of
    /// whatever the microphone's own preamp happened to be set to. It is now the
    /// whole amount, split between the two. Reinterpreting an old value under
    /// the new meaning would drop a typical channel by around 26 dB the first
    /// time it launched — so the first time a device is seen, its current gain
    /// is folded into the number and this is set, and nothing changes audibly.
    var hardwareGainAdopted: Bool = false
    var padEnabled: Bool = false
    var padDB: Float = -20

    var hpfMode: HPFMode = .off
    var hpfFrequency: Float = 100

    var gateEnabled: Bool = false
    var compressorEnabled: Bool = false
    var exciterEnabled: Bool = false
    var bassEnhancerEnabled: Bool = false

    var gate = GateSettings()
    var compressor = CompressorSettings()
    var exciter = ExciterSettings()
    var bassEnhancer = BassEnhancerSettings()

    var faderDB: Float = 0
    var muted: Bool = false
    var soloed: Bool = false

    var id: String { deviceUID }

    init(deviceUID: String, deviceName: String) {
        self.deviceUID = deviceUID
        self.deviceName = deviceName
    }

    // MARK: Decoding

    // Hand-written rather than synthesised, for two reasons.
    //
    // Every field is optional-with-default. `SettingsStore.load()` decodes the
    // whole file as one dictionary with `try?`, so a single unreadable channel
    // does not fail that channel — it discards every setting for every
    // microphone, silently. The synthesised decoder throws on any missing key,
    // which means simply adding a field in a future version would have wiped
    // the user's file on first launch. It never should have been synthesised.
    //
    // And it maps the pre-rename key names. The bass stage used to be called
    // after a term that turns out to be a live trademark, so the property was
    // renamed; the name survives here only long enough to read files written
    // before that, which are then saved back under the new key.

    private enum CodingKeys: String, CodingKey {
        case deviceUID, deviceName
        case gainDB, hardwareGainEnabled, hardwareGainAdopted, padEnabled, padDB
        case hpfMode, hpfFrequency
        case gateEnabled, compressorEnabled, exciterEnabled, bassEnhancerEnabled
        case gate, compressor, exciter, bassEnhancer
        case faderDB, muted, soloed
        case legacyBassEnhancerEnabled = "bigBottomEnabled"
        case legacyBassEnhancer = "bigBottom"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceUID = try c.decode(String.self, forKey: .deviceUID)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? deviceUID

        gainDB = try c.decodeIfPresent(Float.self, forKey: .gainDB) ?? 0
        hardwareGainEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .hardwareGainEnabled) ?? true
        hardwareGainAdopted =
            try c.decodeIfPresent(Bool.self, forKey: .hardwareGainAdopted) ?? false
        padEnabled = try c.decodeIfPresent(Bool.self, forKey: .padEnabled) ?? false
        padDB = try c.decodeIfPresent(Float.self, forKey: .padDB) ?? -20

        hpfMode = try c.decodeIfPresent(HPFMode.self, forKey: .hpfMode) ?? .off
        hpfFrequency = try c.decodeIfPresent(Float.self, forKey: .hpfFrequency) ?? 100

        gateEnabled = try c.decodeIfPresent(Bool.self, forKey: .gateEnabled) ?? false
        compressorEnabled = try c.decodeIfPresent(Bool.self, forKey: .compressorEnabled) ?? false
        exciterEnabled = try c.decodeIfPresent(Bool.self, forKey: .exciterEnabled) ?? false
        bassEnhancerEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .bassEnhancerEnabled)
            ?? c.decodeIfPresent(Bool.self, forKey: .legacyBassEnhancerEnabled)
            ?? false

        gate = try c.decodeIfPresent(GateSettings.self, forKey: .gate) ?? GateSettings()
        compressor = try c.decodeIfPresent(CompressorSettings.self, forKey: .compressor)
            ?? CompressorSettings()
        exciter = try c.decodeIfPresent(ExciterSettings.self, forKey: .exciter) ?? ExciterSettings()
        bassEnhancer =
            try c.decodeIfPresent(BassEnhancerSettings.self, forKey: .bassEnhancer)
            ?? c.decodeIfPresent(BassEnhancerSettings.self, forKey: .legacyBassEnhancer)
            ?? BassEnhancerSettings()

        faderDB = try c.decodeIfPresent(Float.self, forKey: .faderDB) ?? 0
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        soloed = try c.decodeIfPresent(Bool.self, forKey: .soloed) ?? false
    }

    // Written by hand too, so the legacy keys are read but never written back.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deviceUID, forKey: .deviceUID)
        try c.encode(deviceName, forKey: .deviceName)
        try c.encode(gainDB, forKey: .gainDB)
        try c.encode(hardwareGainEnabled, forKey: .hardwareGainEnabled)
        try c.encode(hardwareGainAdopted, forKey: .hardwareGainAdopted)
        try c.encode(padEnabled, forKey: .padEnabled)
        try c.encode(padDB, forKey: .padDB)
        try c.encode(hpfMode, forKey: .hpfMode)
        try c.encode(hpfFrequency, forKey: .hpfFrequency)
        try c.encode(gateEnabled, forKey: .gateEnabled)
        try c.encode(compressorEnabled, forKey: .compressorEnabled)
        try c.encode(exciterEnabled, forKey: .exciterEnabled)
        try c.encode(bassEnhancerEnabled, forKey: .bassEnhancerEnabled)
        try c.encode(gate, forKey: .gate)
        try c.encode(compressor, forKey: .compressor)
        try c.encode(exciter, forKey: .exciter)
        try c.encode(bassEnhancer, forKey: .bassEnhancer)
        try c.encode(faderDB, forKey: .faderDB)
        try c.encode(muted, forKey: .muted)
        try c.encode(soloed, forKey: .soloed)
    }
}

/// Live level information for one channel. Polled by the UI on a timer rather
/// than published per-buffer, so nothing on the render path ever touches
/// SwiftUI or the Swift runtime.
struct ChannelMeters: Equatable {
    var inputPeakDB: Float = -120
    var inputRMSDB: Float = -120
    var outputPeakDB: Float = -120
    var outputRMSDB: Float = -120
    /// Level after the fader and mute — this channel's actual contribution to
    /// the mix, and the value every level meter in the interface shows. See the
    /// note on `ChannelRT.postFaderMeter` for why the pre-fader tap is not it.
    var postFaderPeakDB: Float = -120
    var postFaderRMSDB: Float = -120
    var gateReductionDB: Float = 0
    var compressorReductionDB: Float = 0
    var connected: Bool = false

    /// A copy rounded to the smallest step a reader can actually follow.
    ///
    /// The raw values wander in the third decimal place even in a silent room,
    /// so comparing them is never equal and every tick pushes a UI update for a
    /// change nobody can see. Rounding to 0.5 dB first means a quiet channel
    /// settles and stops redrawing, and the numbers stop flickering.
    func roundedForDisplay() -> ChannelMeters {
        func q(_ v: Float) -> Float { (v * 2).rounded() / 2 }
        return ChannelMeters(
            inputPeakDB: q(inputPeakDB),
            inputRMSDB: q(inputRMSDB),
            outputPeakDB: q(outputPeakDB),
            outputRMSDB: q(outputRMSDB),
            postFaderPeakDB: q(postFaderPeakDB),
            postFaderRMSDB: q(postFaderRMSDB),
            gateReductionDB: q(gateReductionDB),
            compressorReductionDB: q(compressorReductionDB),
            connected: connected)
    }
}

/// Diagnostics surfaced by the clock/drift engine. This is the evidence that the
/// thing this project exists to fix is actually fixed.
struct EngineDiagnostics: Equatable {
    var running: Bool = false
    var sinkAvailable: Bool = false
    var underruns: UInt32 = 0
    var overruns: UInt32 = 0
    /// True when a dropout happened within the last few seconds.
    ///
    /// The totals above are counted for the lifetime of the channel, which makes
    /// them useless as a *status*: binding a device and priming its ring costs a
    /// handful of dropouts every single launch, so any "underruns > 0" test
    /// latches a warning on startup and never clears it. Measured on the
    /// development machine: 11 dropouts during startup, then flat for the next
    /// twelve minutes while the warning stayed lit. That is a permanent false
    /// alarm about the exact fault this project exists to eliminate.
    ///
    /// Recency is the honest signal. It is deliberately a Bool and not "seconds
    /// since", because this struct is compared for equality before it is
    /// published to the interface — a field that changes on every poll would
    /// defeat that and redraw the status line forever. A Bool changes twice per
    /// event. The lifetime totals stay in the details panel, where a cumulative
    /// count is what you actually want.
    var hasRecentDropout: Bool = false
    var droppedParameters: UInt32 = 0
    var perChannelRatioPPM: [String: Double] = [:]
    var perChannelFill: [String: Double] = [:]
    /// Human-readable device name per UID, so the diagnostics panel can say
    /// the microphone's own name rather than a CoreAudio UID string.
    var perChannelName: [String: String] = [:]
    /// Largest gap between two consecutive input callbacks, in microseconds,
    /// since diagnostics were last read. Compare against the device period: at
    /// 48 kHz and 512 frames that is 10 667 us, so a gap of 30 000 us means the
    /// microphone's callback was two periods late. This distinguishes an
    /// external scheduling stall from anything the drift controller could fix.
    var perChannelMaxInputGapUS: [String: UInt32] = [:]
}
