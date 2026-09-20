import SwiftUI

/// The delay-against-crackle choice, shown in the Settings window.
///
/// Each choice states what it costs in milliseconds, worked out from the same
/// numbers the engine uses, so the text cannot drift from the behaviour.
struct LatencySection: View {
    let engine: AudioEngine
    @State private var profile: LatencyProfile

    init(engine: AudioEngine) {
        self.engine = engine
        _profile = State(initialValue: engine.latencyProfile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Delay")
                .font(Theme.labelFont)
                .foregroundColor(Theme.textSecondary)

            Picker("Delay", selection: $profile) {
                ForEach(LatencyProfile.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: profile) { engine.setLatencyProfile($0) }

            Text("\(profile.summary) The noise gate, high-pass, compressor and the other "
                + "filters add no delay of their own at any setting. If you hear crackling, "
                + "choose a safer setting. Changing it restarts the audio for a moment.")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension LatencyProfile {
    var title: String {
        switch self {
        case .lowest: return "Lowest"
        case .balanced: return "Balanced"
        case .safe: return "Safe"
        }
    }

    /// Roughly what OpenConnct itself adds: the cushion in the ring plus a block
    /// on each side of it. The microphone and the receiving app add their own.
    var summary: String {
        let ms = (Double(ringTargetFrames) + 2 * Double(deviceBufferFrames)) / 48.0
        let rounded = Int((ms / 5).rounded()) * 5
        switch self {
        case .lowest: return "About \(rounded) ms. Fastest, but the least forgiving on a busy Mac."
        case .balanced: return "About \(rounded) ms. A good middle for most setups."
        case .safe: return "About \(rounded) ms. Slowest, and the least likely to crackle."
        }
    }
}
