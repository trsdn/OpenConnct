import XCTest
import OpenConnctDSP
import OpenConnctDSPShim

private let driftSampleRate = 48_000.0
private let driftRingCapacity: UInt32 = 32_768
private let driftTargetFill: Float = 1_536
private let driftKp: Float = 2.8e-6
private let driftKi: Float = 1.2e-9
private let driftIntegratorLimit: Float = 5.0e-4
private let driftRatioLimit: Float = 1.0e-3
private let driftSlewPerUpdate: Float = 5.0e-6

private struct DriftMetrics {
    var ppm: Double
    var seconds: Double
    var blocks: Int
    var minFill: UInt32 = .max
    var maxFill: UInt32 = 0
    var settledFillMean: Double = 0
    var settledCorrectionMean: Double = 1
    var settledCorrectionPPM: Double { (settledCorrectionMean - 1.0) * 1.0e6 }
    var maxCorrectionOffset: Float = 0
    var maxCorrectionSlew: Float = 0
    var underrunsTotal: UInt32 = 0
    var underrunsAfterSettling: UInt32 = 0
    var overrunsTotal: UInt32 = 0
    var overrunsAfterSettling: UInt32 = 0
    /// Largest |fill - target| seen after a step disturbance ended. A pure
    /// integrating loop rings, so this catches an overshoot that the mean and
    /// the xrun count both hide.
    var peakErrorAfterDisturbance: Double = 0
    /// Seconds from the end of the disturbance until |fill - target| stays
    /// inside `settlingTolerance` for good.
    var settlingSecondsAfterDisturbance: Double = 0
    var thd: Float?
    var maxFirstDifference: Float?
    var sineSlewLimit: Float?
}

private final class DriftSimulator {
    let ppm: Double
    let seconds: Double
    let blockSize: Int
    let settlingBlocks: Int
    let sineFrequency: Double?
    let captureTailFrames: Int
    let stallBlocks: Range<Int>?

    init(
        ppm: Double,
        seconds: Double,
        blockSize: Int = 256,
        settlingSeconds: Double = 20,
        sineFrequency: Double? = nil,
        captureTailSeconds: Double = 0,
        stallBlocks: Range<Int>? = nil
    ) {
        self.ppm = ppm
        self.seconds = seconds
        self.blockSize = blockSize
        self.settlingBlocks = Int(settlingSeconds * driftSampleRate / Double(blockSize))
        self.sineFrequency = sineFrequency
        self.captureTailFrames = Int(captureTailSeconds * driftSampleRate)
        self.stallBlocks = stallBlocks
    }

    func run() -> DriftMetrics {
        let totalBlocks = Int(seconds * driftSampleRate / Double(blockSize))
        let micRate = driftSampleRate * (1.0 + ppm * 1.0e-6)
        let initialFill = max(4, Int(driftTargetFill) - blockSize)
        let maxProduce = blockSize + 8

        var storage = Array(repeating: Float(0), count: Int(driftRingCapacity))
        var produce = Array(repeating: Float(0), count: maxProduce)
        var output = Array(repeating: Float(0), count: blockSize)
        var discard = Array(repeating: Float(0), count: maxProduce)
        var tail = Array(repeating: Float(0), count: max(captureTailFrames, 1))
        var tailIndex = 0
        var tailFilled = false

        var metrics = DriftMetrics(ppm: ppm, seconds: seconds, blocks: totalBlocks)
        var producerRemainder = 0.0
        var sourceIndex: Int64 = 0
        var previousCorrection = Float(1)
        var steadyFillSum = 0.0
        var steadyCorrectionSum = 0.0
        var steadyCount = 0
        let steadyStart = max(settlingBlocks, totalBlocks * 8 / 10)
        var previousOutput: Float?
        var maxFirstDifference: Float = 0
        let disturbanceEnd = stallBlocks?.upperBound
        var lastUnsettledBlock = disturbanceEnd

        storage.withUnsafeMutableBufferPointer { storagePointer in
            produce.withUnsafeMutableBufferPointer { producePointer in
                output.withUnsafeMutableBufferPointer { outputPointer in
                    discard.withUnsafeMutableBufferPointer { discardPointer in
                        var ring = oc_ring_buffer()
                        XCTAssertEqual(oc_ring_buffer_init(&ring, storagePointer.baseAddress!, driftRingCapacity), 1)
                        var resampler = oc_resampler()
                        oc_resampler_init(&resampler, 1.0)
                        var drift = oc_drift_controller()
                        oc_drift_controller_init(
                            &drift, driftTargetFill, driftKp, driftKi,
                            driftIntegratorLimit, driftRatioLimit, driftSlewPerUpdate)

                        writeInput(
                            count: initialFill, micRate: micRate, sineFrequency: sineFrequency,
                            sourceIndex: &sourceIndex, buffer: producePointer, ring: &ring)

                        for block in 0..<totalBlocks {
                            let inputFrames: Int
                            if stallBlocks?.contains(block) == true {
                                inputFrames = 0
                            } else {
                                producerRemainder += Double(blockSize) * micRate / driftSampleRate
                                inputFrames = Int(producerRemainder.rounded(.down))
                                producerRemainder -= Double(inputFrames)
                            }

                            if inputFrames > 0 {
                                let overrunCount = writeInput(
                                    count: inputFrames, micRate: micRate, sineFrequency: sineFrequency,
                                    sourceIndex: &sourceIndex, buffer: producePointer, ring: &ring)
                                metrics.overrunsTotal &+= UInt32(overrunCount)
                                if block >= settlingBlocks {
                                    metrics.overrunsAfterSettling &+= UInt32(overrunCount)
                                }
                            }

                            let fill = oc_ring_buffer_fill_level(&ring)
                            let correction = oc_drift_controller_update(&drift, Float(fill))
                            oc_resampler_set_ratio(&resampler, Double(correction))

                            metrics.maxCorrectionOffset = max(metrics.maxCorrectionOffset, abs(correction - 1))
                            metrics.maxCorrectionSlew = max(metrics.maxCorrectionSlew, abs(correction - previousCorrection))
                            previousCorrection = correction

                            let produced = oc_resampler_pull(&resampler, &ring, outputPointer.baseAddress!, UInt32(blockSize))
                            if produced < UInt32(blockSize) {
                                metrics.underrunsTotal &+= 1
                                if block >= settlingBlocks { metrics.underrunsAfterSettling &+= 1 }
                            }

                            let postFill = oc_ring_buffer_fill_level(&ring)
                            metrics.minFill = min(metrics.minFill, fill, postFill)
                            metrics.maxFill = max(metrics.maxFill, fill, postFill)

                            if let disturbanceEnd, block >= disturbanceEnd {
                                let err = abs(Double(fill) - Double(driftTargetFill))
                                metrics.peakErrorAfterDisturbance =
                                    max(metrics.peakErrorAfterDisturbance, err)
                                if err > Self.settlingTolerance { lastUnsettledBlock = block }
                            }

                            if block >= steadyStart {
                                steadyFillSum += Double(fill)
                                steadyCorrectionSum += Double(correction)
                                steadyCount += 1
                            }

                            if sineFrequency != nil && block >= settlingBlocks {
                                for i in 0..<blockSize {
                                    let sample = outputPointer[i]
                                    if let previousOutput {
                                        maxFirstDifference = max(maxFirstDifference, abs(sample - previousOutput))
                                    }
                                    previousOutput = sample
                                    if captureTailFrames > 0 {
                                        tail[tailIndex] = sample
                                        tailIndex += 1
                                        if tailIndex == captureTailFrames {
                                            tailIndex = 0
                                            tailFilled = true
                                        }
                                    }
                                }
                            }

                            _ = discardPointer.baseAddress
                        }
                    }
                }
            }
        }

        if let disturbanceEnd, let lastUnsettledBlock {
            metrics.settlingSecondsAfterDisturbance =
                Double(lastUnsettledBlock - disturbanceEnd) * Double(blockSize) / driftSampleRate
        }

        if steadyCount > 0 {
            metrics.settledFillMean = steadyFillSum / Double(steadyCount)
            metrics.settledCorrectionMean = steadyCorrectionSum / Double(steadyCount)
        }

        if let sineFrequency, captureTailFrames > 0 {
            let captured: [Float]
            if tailFilled {
                captured = Array(tail[tailIndex..<captureTailFrames] + tail[0..<tailIndex])
            } else {
                captured = Array(tail[0..<tailIndex])
            }
            metrics.thd = Analysis.thd(captured, fundamental: Float(sineFrequency), sampleRate: Float(driftSampleRate), harmonics: 6)
            metrics.maxFirstDifference = maxFirstDifference
            metrics.sineSlewLimit = Float(2.0 * 0.20 * sin(.pi * sineFrequency / driftSampleRate))
        }

        return metrics
    }

    /// How close to target counts as settled. One block of the hardware period
    /// is the resolution the ring actually moves in, so anything tighter would
    /// be measuring quantisation rather than the controller.
    static let settlingTolerance = 32.0

    @discardableResult
    private func writeInput(
        count: Int,
        micRate: Double,
        sineFrequency: Double?,
        sourceIndex: inout Int64,
        buffer: UnsafeMutableBufferPointer<Float>,
        ring: inout oc_ring_buffer
    ) -> Int {
        var remaining = count
        var overruns = 0
        while remaining > 0 {
            let chunk = min(remaining, buffer.count)
            if let sineFrequency {
                for i in 0..<chunk {
                    let t = Double(sourceIndex + Int64(i)) / micRate
                    buffer[i] = Float(0.20 * sin(2.0 * .pi * sineFrequency * t))
                }
            } else {
                for i in 0..<chunk { buffer[i] = 0 }
            }

            let written = oc_ring_buffer_write(&ring, buffer.baseAddress!, UInt32(chunk))
            if written < UInt32(chunk) {
                overruns += 1
            }
            sourceIndex += Int64(chunk)
            remaining -= chunk
        }
        return overruns
    }
}

final class DriftSoakTests: XCTestCase {
    func testMatchedClocksStayAtTargetWithoutXRuns() {
        let metrics = DriftSimulator(ppm: 0, seconds: 90).run()
        printMetrics("matched clocks", metrics)
        XCTAssertEqual(metrics.underrunsTotal, 0)
        XCTAssertEqual(metrics.overrunsTotal, 0)
        XCTAssertEqual(metrics.settledFillMean, Double(driftTargetFill), accuracy: 16)
        XCTAssertEqual(metrics.settledCorrectionPPM, 0, accuracy: 2)
        XCTAssertLessThanOrEqual(metrics.maxCorrectionOffset, driftRatioLimit + 1.0e-7)
        XCTAssertLessThanOrEqual(metrics.maxCorrectionSlew, driftSlewPerUpdate + 1.0e-7)
    }

    func testFasterMicrophoneClocksConvergeAndRemainBounded() {
        for ppm in [50.0, 200.0] {
            let metrics = DriftSimulator(ppm: ppm, seconds: 240).run()
            printMetrics("fast mic \(ppm) ppm", metrics)
            assertStable(metrics, expectedPPM: ppm)
        }
    }

    func testSlowerMicrophoneClocksConvergeAndRemainBounded() {
        for ppm in [-50.0, -200.0] {
            let metrics = DriftSimulator(ppm: ppm, seconds: 240).run()
            printMetrics("slow mic \(ppm) ppm", metrics)
            assertStable(metrics, expectedPPM: ppm)
        }
    }

    func testTwoOppositeDriftChannelsShareTheOutputClock() {
        let fast = DriftSimulator(ppm: 80, seconds: 180).run()
        let slow = DriftSimulator(ppm: -80, seconds: 180).run()
        printMetrics("opposite drift +80 ppm", fast)
        printMetrics("opposite drift -80 ppm", slow)
        assertStable(fast, expectedPPM: 80)
        assertStable(slow, expectedPPM: -80)
    }

    func testTwoHourDriftSoakHasNoSteadyStateXRuns() {
        let metrics = DriftSimulator(ppm: 200, seconds: 2 * 60 * 60, blockSize: 1_024, settlingSeconds: 120).run()
        printMetrics("two hour +200 ppm soak", metrics)
        assertStable(metrics, expectedPPM: 200, fillTolerance: 128, ppmTolerance: 35)
    }

    func testDriftingSineStaysCleanAndClickFree() {
        let metrics = DriftSimulator(
            ppm: 80,
            seconds: 180,
            blockSize: 256,
            settlingSeconds: 60,
            sineFrequency: 1_000,
            captureTailSeconds: 1).run()

        printMetrics("drifting 1 kHz sine +80 ppm", metrics)
        XCTAssertEqual(metrics.underrunsAfterSettling, 0)
        XCTAssertEqual(metrics.overrunsAfterSettling, 0)
        XCTAssertLessThan(metrics.thd ?? 1, 0.003)
        XCTAssertLessThan(metrics.maxFirstDifference ?? 1, (metrics.sineSlewLimit ?? 0) * 2.5)
    }

    /// A one-block step disturbance, which is what real hardware actually does.
    ///
    /// A fifteen-minute soak with two USB microphones showed the ring fill
    /// jumping by exactly one 512-frame hardware period every few minutes —
    /// a scheduling hiccup where one side ran a cycle without the other. That
    /// is not drift and cannot be prevented here; the question is only how
    /// gracefully the controller absorbs it.
    ///
    /// The observed answer was: badly. Fill went from 1536 to 1024, overshot
    /// the other way to 1705, came back down to 28 — within a whisker of an
    /// underrun — and took about six minutes of visible ringing to settle. One
    /// real underrun was recorded when a second step arrived during recovery.
    /// This test pins the response down so that cannot regress.
    func testControllerAbsorbsAOneBlockStepWithoutRinging() {
        let blockSize = 512
        let stallStart = Int(30 * driftSampleRate / Double(blockSize))
        let metrics = DriftSimulator(
            ppm: 0, seconds: 600, blockSize: blockSize,
            stallBlocks: stallStart..<(stallStart + 1)).run()
        printMetrics("one-block (512 frame) step disturbance", metrics)

        // The step itself is 512 frames. Anything much beyond that is the
        // controller adding its own excursion on top of the disturbance.
        XCTAssertLessThan(metrics.peakErrorAfterDisturbance, 640)
        // Six minutes of ringing was the defect. Ninety seconds is generous for
        // a correction that is inaudible the whole time it is happening.
        XCTAssertLessThan(metrics.settlingSecondsAfterDisturbance, 90)
        XCTAssertEqual(metrics.underrunsTotal, 0)
        XCTAssertEqual(metrics.overrunsTotal, 0)
        XCTAssertLessThan(metrics.maxCorrectionOffset, driftRatioLimit + 1.0e-7)
    }

    func testControllerRecoversFromShortProducerStall() {
        let stallStart = Int(30 * driftSampleRate / 256)
        let metrics = DriftSimulator(ppm: 0, seconds: 180, stallBlocks: stallStart..<(stallStart + 4)).run()
        printMetrics("four-block producer stall recovery", metrics)
        XCTAssertEqual(metrics.underrunsAfterSettling, 0)
        XCTAssertEqual(metrics.overrunsAfterSettling, 0)
        XCTAssertEqual(metrics.settledFillMean, Double(driftTargetFill), accuracy: 96)
        XCTAssertEqual(metrics.settledCorrectionPPM, 0, accuracy: 30)
        XCTAssertLessThan(metrics.maxCorrectionOffset, driftRatioLimit + 1.0e-7)
    }

    private func assertStable(
        _ metrics: DriftMetrics,
        expectedPPM: Double,
        fillTolerance: Double = 96,
        ppmTolerance: Double = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThan(metrics.minFill, 4, file: file, line: line)
        XCTAssertLessThan(metrics.maxFill, driftRingCapacity - 4, file: file, line: line)
        XCTAssertEqual(metrics.underrunsAfterSettling, 0, file: file, line: line)
        XCTAssertEqual(metrics.overrunsAfterSettling, 0, file: file, line: line)
        XCTAssertEqual(metrics.settledFillMean, Double(driftTargetFill), accuracy: fillTolerance, file: file, line: line)
        XCTAssertEqual(metrics.settledCorrectionPPM, expectedPPM, accuracy: ppmTolerance, file: file, line: line)
        XCTAssertLessThanOrEqual(metrics.maxCorrectionOffset, driftRatioLimit + 1.0e-7, file: file, line: line)
        XCTAssertLessThanOrEqual(metrics.maxCorrectionSlew, driftSlewPerUpdate + 1.0e-7, file: file, line: line)
    }

    private func printMetrics(_ label: String, _ metrics: DriftMetrics) {
        var parts = [
            "[DriftSoak] \(label): fill mean \(String(format: "%.1f", metrics.settledFillMean)) frames",
            "range \(metrics.minFill)...\(metrics.maxFill)",
            "correction \(String(format: "%.2f", metrics.settledCorrectionPPM)) ppm vs true \(String(format: "%.2f", metrics.ppm)) ppm",
            "underruns \(metrics.underrunsAfterSettling)/\(metrics.underrunsTotal)",
            "overruns \(metrics.overrunsAfterSettling)/\(metrics.overrunsTotal)",
            "max slew \(String(format: "%.3f", metrics.maxCorrectionSlew * 1.0e6)) ppm/update"
        ]
        if metrics.peakErrorAfterDisturbance > 0 {
            parts.append("peak error after step \(String(format: "%.0f", metrics.peakErrorAfterDisturbance)) frames")
            parts.append("settled in \(String(format: "%.1f", metrics.settlingSecondsAfterDisturbance)) s")
        }
        if let thd = metrics.thd {            parts.append("THD \(String(format: "%.5f", thd))")
        }
        if let diff = metrics.maxFirstDifference, let limit = metrics.sineSlewLimit {
            parts.append("max Δ \(String(format: "%.5f", diff)) allowed \(String(format: "%.5f", limit * 2.5))")
        }
        print(parts.joined(separator: ", "))
    }
}
