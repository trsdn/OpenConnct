import Foundation
import Combine

// MARK: - Guided gain calibration, the part that needs a microphone
//
// The arithmetic lives in `GainCalibration` in Core, apart from the hardware,
// so it can be tested against a table. This is the other half: run a clock,
// collect readings from the right tap, and hand them over.
//
// It pulls from the store on its own timer rather than being fed by the meter
// poll. The meter rate is a user-settable trade (`OPENCONNCT_METER_HZ`) and can
// legitimately be set to zero; a measurement that silently never finishes
// because the meters are off would be a bad way to find that out.

@MainActor
final class GainCalibrationSession: ObservableObject, Identifiable {

    nonisolated let id = UUID()

    /// The sentence the user is asked to read.
    ///
    /// Not decoration. Speech level is meaningless without knowing what was
    /// said: the peak-to-average ratio of a sentence varies by more than 6 dB
    /// with its content, and it is the peaks that decide the headroom.
    ///
    /// So this one is chosen for its consonants. "Pick", "up", "box", "put",
    /// "back", "top" carry the plosives that produce the peaks — a sentence
    /// without them measures several dB low, and the calibration then clips on
    /// the first hard consonant of the real call. "Please" and "shelf" carry the
    /// sibilants. It is short enough to say without self-consciousness and dull
    /// enough to say out loud in an office.
    ///
    /// Reading a *known* sentence also stops people trailing off, which is what
    /// happens when you ask someone to "say something".
    static let sentence = "Please pick up the box and put it back on the top shelf."

    enum Phase: Equatable {
        /// Discarding readings while the meter's own 300 ms decay drains the
        /// click of the button that started this.
        case settling
        case silence
        case speech
        case finished
        case failed(String)

        var isMeasuring: Bool { self == .silence || self == .speech }
    }

    // Durations. The silence window is short because a room is stationary over
    // two seconds; the speech window is the length of the sentence plus room to
    // start late.
    private static let settleSeconds = 0.6
    private static let silenceSeconds = 2.0
    private static let speechSeconds = 5.0
    private static let tickHz = 20.0

    /// How much of the readings to keep, for the voice. See
    /// `GainCalibration.percentile` for why this is not the maximum.
    private static let speechPercentile: Float = 0.95

    /// And for the room — deliberately the middle, not a high percentile.
    ///
    /// This was 0.95 for both, and it was wrong in a way that only showed up
    /// against a real room. The reading being sampled is a *peak* meter, so a
    /// high percentile of two seconds of "silence" reports the loudest
    /// transient in it: one keyboard tap, one chair creak. Measured here, a
    /// quiet room read -10.9 dBFS peak against -33.9 dBFS RMS — a 23 dB crest
    /// that was entirely typing. Against a floor like that, ordinary speech
    /// fails to clear the 6 dB bar and the calibration refuses with "nothing
    /// was heard", which is both wrong and unhelpful.
    ///
    /// The floor wants the room as it usually is, so the middle of the
    /// distribution is the right statistic. The voice wants the loud parts,
    /// so it keeps the high one. They are different questions.
    private static let silencePercentile: Float = 0.5

    /// And the level the voice had to *hold* rather than merely touch, which is
    /// what tells a sentence apart from a room. Sixty rather than fifty because
    /// the sentence takes about three and a half of the five seconds on offer,
    /// so roughly a third of the window is legitimately silent; the middle of
    /// the window sits uncomfortably close to that boundary.
    private static let sustainedPercentile: Float = 0.6

    let deviceUID: String
    @Published private(set) var phase: Phase = .settling
    /// Whole seconds, so the countdown does not push a redraw twenty times a
    /// second for a number nobody can read that fast.
    @Published private(set) var secondsLeft: Int = 0
    /// Post-gain level, for a small live meter during the measurement. Without
    /// it the user is staring at a countdown with no evidence anything is being
    /// heard at all.
    ///
    /// Quantised to a decibel and only republished on a real change, for the
    /// same reason every other meter in this app is: a `@Published` write fires
    /// whether or not the value moved, and this one is observed by a sheet.
    @Published private(set) var liveLevelDB: Float = -120
    @Published private(set) var result: GainCalibrationResult?

    private weak var store: ParameterStore?
    private var timer: Timer?
    private var elapsed = 0.0
    private var silenceReadings: [Float] = []
    private var speechReadings: [Float] = []
    private var rawSpeechReadings: [Float] = []
    private var gainAtStart: Float = 0

    init(deviceUID: String, store: ParameterStore) {
        self.deviceUID = deviceUID
        self.store = store
    }

    deinit { timer?.invalidate() }

    func start() {
        guard let store, let sample = store.calibrationSample(for: deviceUID) else {
            phase = .failed("This microphone is no longer connected.")
            return
        }
        gainAtStart = sample.gainDB
        phase = .settling
        elapsed = 0
        secondsLeft = Int(Self.silenceSeconds.rounded(.up))
        silenceReadings.removeAll(keepingCapacity: true)
        speechReadings.removeAll(keepingCapacity: true)
        rawSpeechReadings.removeAll(keepingCapacity: true)
        result = nil

        let t = Timer(timeInterval: 1.0 / Self.tickHz, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    /// Writes the proposal to the channel. Nothing is applied without this.
    func apply() {
        guard let store, let result,
              case let .adjust(newGainDB, _) = result.outcome else { return }
        store.update(deviceUID) { $0.gainDB = newGainDB }
    }

    /// The best that can be done when there is not enough gain — offered
    /// separately, because accepting a level that is still too quiet should be
    /// a different press from accepting a correct one.
    func applyBestEffort() {
        guard let store, let result,
              case let .notEnoughGain(bestGainDB, _) = result.outcome else { return }
        store.update(deviceUID) { $0.gainDB = bestGainDB }
    }

    // MARK: - The clock

    private func tick() {
        guard let store, let sample = store.calibrationSample(for: deviceUID) else {
            phase = .failed("This microphone was disconnected during the measurement.")
            cancel()
            return
        }

        publishLevel(sample.postGainPeakDB)
        elapsed += 1.0 / Self.tickHz

        switch phase {
        case .settling:
            if elapsed >= Self.settleSeconds {
                phase = .silence
                elapsed = 0
            }
            publishCountdown(Self.silenceSeconds)

        case .silence:
            silenceReadings.append(sample.postGainPeakDB)
            publishCountdown(Self.silenceSeconds - elapsed)
            if elapsed >= Self.silenceSeconds {
                phase = .speech
                elapsed = 0
                publishCountdown(Self.speechSeconds)
            }

        case .speech:
            speechReadings.append(sample.postGainPeakDB)
            rawSpeechReadings.append(sample.rawPeakDB)
            publishCountdown(Self.speechSeconds - elapsed)
            if elapsed >= Self.speechSeconds {
                finish()
            }

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

    /// Ends the speech window early. The sentence takes about three seconds and
    /// the window allows five, so without this the user reads it and then waits,
    /// which measures two seconds of them waiting.
    func finishEarly() {
        guard phase == .speech else { return }
        finish()
    }

    private func finish() {
        cancel()
        guard let speech = GainCalibration.percentile(speechReadings, Self.speechPercentile),
              let noise = GainCalibration.percentile(silenceReadings, Self.silencePercentile),
              let sustained = GainCalibration.percentile(speechReadings, Self.sustainedPercentile),
              let raw = GainCalibration.percentile(rawSpeechReadings, Self.speechPercentile)
        else {
            phase = .failed("The measurement produced no readings.")
            return
        }

        result = GainCalibration.evaluate(
            speechPeakDB: speech,
            sustainedSpeechDB: sustained,
            noiseFloorDB: noise,
            rawPeakDB: raw,
            currentGainDB: gainAtStart,
            gainRange: store?.gainRange(for: deviceUID) ?? -20...40,
            targetLowDB: meterTargetLowDB,
            targetHighDB: meterTargetHighDB,
            clipDB: meterRedDB)
        phase = .finished
    }
}
