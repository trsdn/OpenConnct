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
}

/// Diagnostics surfaced by the clock/drift engine. This is the evidence that the
/// thing this project exists to fix is actually fixed.
struct EngineDiagnostics: Equatable {
    var running: Bool = false
    var sinkAvailable: Bool = false
    var underruns: UInt32 = 0
    var overruns: UInt32 = 0
    var droppedParameters: UInt32 = 0
    var perChannelRatioPPM: [String: Double] = [:]
    var perChannelFill: [String: Double] = [:]
    /// Human-readable device name per UID, so the diagnostics panel can say
    /// "RØDE NT-USB Mini" rather than a CoreAudio UID string.
    var perChannelName: [String: String] = [:]
}
