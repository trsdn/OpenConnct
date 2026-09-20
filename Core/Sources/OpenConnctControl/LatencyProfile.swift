import Foundation

/// How much delay OpenConnct trades for safety against crackling.
///
/// Two buffers set the delay OpenConnct adds: the block size the microphone and
/// the virtual device are run at, and the cushion the ring keeps between them to
/// absorb USB scheduling jitter. Nothing in the signal chain adds delay of its
/// own, so these two numbers are the whole story. Smaller is faster and less
/// forgiving; a machine that is busy, or a microphone on a hub, may need more.
public enum LatencyProfile: String, CaseIterable, Equatable {
    case lowest
    case balanced
    /// What OpenConnct did before profiles existed.
    case safe

    /// Frames per hardware block, requested from the microphones and the virtual device.
    public var deviceBufferFrames: Int {
        switch self {
        case .lowest: return 128
        case .balanced: return 256
        case .safe: return 512
        }
    }

    /// Steady-state ring occupancy the drift controller aims for, in frames.
    public var ringTargetFrames: Float {
        switch self {
        case .lowest: return 384
        case .balanced: return 768
        case .safe: return 1536
        }
    }

    /// The drift controller's proportional gain for this block size.
    ///
    /// The loop updates once per block, so its damping ratio is
    /// `block·kp / (2·√(block·ki))`, which falls with √block. `kp` is scaled by
    /// √(512/block) so the damping stays where it was tuned to be at 512 frames.
    public var driftProportionalGain: Double {
        2.8e-6 * (512.0 / Double(deviceBufferFrames)).squareRoot()
    }

    public init(storedValue: String?) {
        self = storedValue.flatMap(LatencyProfile.init(rawValue:)) ?? .safe
    }
}
