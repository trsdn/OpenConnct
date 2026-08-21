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
    var holdMS: Float = 80
    var releaseMS: Float = 150
    var hysteresisDB: Float = 6
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

struct BigBottomSettings: Codable, Equatable {
    var amount: Float = 0.35
    var frequency: Float = 120
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
    var padEnabled: Bool = false
    var padDB: Float = -20

    var hpfMode: HPFMode = .off
    var hpfFrequency: Float = 100

    var gateEnabled: Bool = false
    var compressorEnabled: Bool = false
    var exciterEnabled: Bool = false
    var bigBottomEnabled: Bool = false

    var gate = GateSettings()
    var compressor = CompressorSettings()
    var exciter = ExciterSettings()
    var bigBottom = BigBottomSettings()

    var faderDB: Float = 0
    var muted: Bool = false
    var soloed: Bool = false

    var id: String { deviceUID }

    init(deviceUID: String, deviceName: String) {
        self.deviceUID = deviceUID
        self.deviceName = deviceName
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
    /// "RØDE NT-USB Mini" rather than a CoreAudio UID string.
    var perChannelName: [String: String] = [:]
    /// Largest gap between two consecutive input callbacks, in microseconds,
    /// since diagnostics were last read. Compare against the device period: at
    /// 48 kHz and 512 frames that is 10 667 us, so a gap of 30 000 us means the
    /// microphone's callback was two periods late. This distinguishes an
    /// external scheduling stall from anything the drift controller could fix.
    var perChannelMaxInputGapUS: [String: UInt32] = [:]
}
