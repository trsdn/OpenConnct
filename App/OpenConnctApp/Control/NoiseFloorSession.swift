import Foundation
import Combine

// MARK: - Measuring a noise floor, the part that needs a microphone
//
// The arithmetic is in `NoiseFloorCalibration` in Core. This is the other half:
// arm the probe, run a clock, collect readings, hand them over, disarm.
//
// Simpler than the gain calibration, and deliberately so. There is one window
// and nothing to read aloud — the user is asked to be quiet, which is a thing
// they can do without thinking about it. That is worth the asymmetry: the more
// a measurement asks of someone, the more ways it has of being done wrong.

@MainActor
final class NoiseFloorSession: ObservableObject, Identifiable {

    nonisolated let id = UUID()

    enum Phase: Equatable {
        /// Discarding readings while the probe's own envelope settles and the
        /// click of the button that started this passes.
        case settling
        case measuring
        case finished
        case failed(String)
    }

    /// The probe's detector releases over 25 ms, so a tenth of a second is four
    /// time constants — long enough that nothing of the button press survives.
    /// Longer would only make the user wait.
    private static let settleSeconds = 0.4
    /// A room is stationary over a couple of seconds. Three rather than two
    /// because a slow fan or a hard drive has a cycle, and two seconds can
    /// happen entirely inside a quiet part of it.
    private static let measureSeconds = 3.0
    private static let tickHz = 20.0

    /// See the note at the top of `NoiseFloorCalibration` for why this is high
    /// where the gain calibration's equivalent is the middle. Ninety rather
    /// than a hundred so that the one door or one dropped pen a three-second
    /// window reliably contains does not set the threshold on its own.
    private static let floorPercentile: Float = 0.9

    let deviceUID: String
    @Published private(set) var phase: Phase = .settling
    @Published private(set) var secondsLeft: Int = 0
    /// Live probe reading, so the user can see that something is being heard
    /// rather than watching a countdown on faith.
    @Published private(set) var liveLevelDB: Float = -120
    @Published private(set) var result: NoiseFloorResult?

    private weak var store: ParameterStore?
    private var timer: Timer?
    private var elapsed = 0.0
    private var readings: [Float] = []
    private var thresholdAtStart: Float = 0

    init(deviceUID: String, store: ParameterStore) {
        self.deviceUID = deviceUID
        self.store = store
    }

    deinit { timer?.invalidate() }

    func start() {
        guard let store else { return }
        guard let settings = store.channel(for: deviceUID) else {
            phase = .failed("This microphone is no longer connected.")
            return
        }
        // Checked rather than measured. A muted channel has its whole chain
        // skipped, so the probe would sit in a part of the signal path that is
        // not running and report an empty room -- a wrong answer that looks
        // exactly like a right one.
        guard !store.isSilenced(deviceUID) else {
            phase = .failed("This microphone is muted, so there is nothing to measure yet. "
                            + "Unmute it and try again.")
            return
        }

        thresholdAtStart = settings.gate.thresholdDB
        phase = .settling
        elapsed = 0
        secondsLeft = Int(Self.measureSeconds.rounded(.up))
        readings.removeAll(keepingCapacity: true)
        result = nil

        store.armNoiseProbe(true, for: deviceUID)

        let t = Timer(timeInterval: 1.0 / Self.tickHz, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        store?.armNoiseProbe(false, for: deviceUID)
    }

    /// Writes the proposal. Nothing is applied without this.
    func apply() {
        guard let store, let result,
              case let .propose(thresholdDB) = result.outcome else { return }
        store.update(deviceUID) { $0.gate.thresholdDB = thresholdDB }
    }

    /// Switching the gate on is part of accepting the answer. Someone who has
    /// just measured a threshold wants the gate to use it, and finding it still
    /// switched off afterwards is the failure this whole feature exists to fix.
    func applyAndEnable() {
        guard let store, let result,
              case let .propose(thresholdDB) = result.outcome else { return }
        store.update(deviceUID) {
            $0.gate.thresholdDB = thresholdDB
            $0.gateEnabled = true
        }
    }

    private func tick() {
        guard let store, let reading = store.noiseProbeReading(for: deviceUID) else {
            phase = .failed("This microphone was disconnected during the measurement.")
            cancel()
            return
        }

        publishLevel(reading)
        elapsed += 1.0 / Self.tickHz

        switch phase {
        case .settling:
            // The reading is still taken and thrown away, because reading is
            // what restarts the probe's running maximum. Leaving it unread
            // would carry the button click into the first real sample.
            if elapsed >= Self.settleSeconds {
                phase = .measuring
                elapsed = 0
            }
            publishCountdown(Self.measureSeconds)

        case .measuring:
            readings.append(reading)
            publishCountdown(Self.measureSeconds - elapsed)
            if elapsed >= Self.measureSeconds { finish() }

        case .finished, .failed:
            cancel()
        }
    }

    private func publishCountdown(_ seconds: Double) {
        let whole = Int(max(0, seconds).rounded(.up))
        if secondsLeft != whole { secondsLeft = whole }
    }

    private func publishLevel(_ db: Float) {
        let q = db.rounded()
        if liveLevelDB != q { liveLevelDB = q }
    }

    private func finish() {
        cancel()
        guard let floor = GainCalibration.percentile(readings, Self.floorPercentile) else {
            phase = .failed("The measurement produced no readings.")
            return
        }
        result = NoiseFloorCalibration.evaluate(
            floorDB: floor,
            previousThresholdDB: thresholdAtStart,
            thresholdRange: gateThresholdRange)
        phase = .finished
    }
}

/// The range the threshold slider offers. Defined here and used by both, so the
/// calibration cannot propose a value the control will not accept.
let gateThresholdRange: ClosedRange<Float> = -80...0
