import Foundation

/// Identifiers for individual parameter changes sent from the UI thread to the
/// render thread through the lock-free SPSC queue in the DSP core.
///
/// The wire format is a single `UInt32`: the low 16 bits are the parameter, the
/// high 16 bits are the channel index. Values are always `Float`, so booleans
/// and enums are encoded as 0/1 and raw case values respectively.
enum OCParam: UInt32 {
    case gainDB = 1
    case padDB = 2
    case padEnabled = 3
    case hpfMode = 4
    case hpfFrequency = 5

    case gateEnabled = 10
    case gateThresholdDB = 11
    case gateAttackMS = 12
    case gateHoldMS = 13
    case gateReleaseMS = 14
    case gateHysteresisDB = 15
    case gateRangeDB = 16

    case compressorEnabled = 20
    case compThresholdDB = 21
    case compRatio = 22
    case compAttackMS = 23
    case compReleaseMS = 24
    case compMakeupDB = 25
    case compKneeDB = 26

    case exciterEnabled = 30
    case exciterAmount = 31
    case exciterFrequency = 32
    case exciterDrive = 33

    case bigBottomEnabled = 40
    case bigBottomAmount = 41
    case bigBottomFrequency = 42
    case bigBottomDrive = 43

    case faderDB = 50
    case muted = 51
    /// Effective mute after solo resolution, computed on the UI side so the
    /// render thread never has to reason about the state of other channels.
    case effectivelyMuted = 52

    /// Packs a channel index and this parameter into the queue's 32-bit id.
    func packed(channel: Int) -> UInt32 {
        (UInt32(channel) << 16) | rawValue
    }

    static func unpack(_ id: UInt32) -> (channel: Int, param: OCParam?) {
        (Int(id >> 16), OCParam(rawValue: id & 0xFFFF))
    }
}
