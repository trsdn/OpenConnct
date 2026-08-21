import XCTest
import OpenConnectDSP
import OpenConnectDSPShim

final class OpenConnectDSPTests: XCTestCase {
    let sr: Float = 48_000

    func process(_ b: inout oc_biquad, _ input: [Float]) -> [Float] {
        var out = Array(repeating: Float(0), count: input.count)
        input.withUnsafeBufferPointer { ib in
            out.withUnsafeMutableBufferPointer { ob in
                oc_biquad_process_block(&b, ib.baseAddress!, ob.baseAddress!, UInt32(input.count))
            }
        }
        return out
    }

    func hpfGain(cutoff: Float, probe: Float) -> Float {
        var b = oc_biquad()
        oc_biquad_set_highpass(&b, Double(sr), cutoff, 0.70710678)
        let x = SignalGenerator.sine(frequency: probe, sampleRate: sr, count: 48_000, amplitude: 0.25)
        let y = process(&b, x)
        return Analysis.db(Analysis.rms(y, dropFirst: 24_000) / (0.25 / sqrt(2)))
    }

    func testBiquad75HzCutoffIsMinus3dB() {
        XCTAssertEqual(hpfGain(cutoff: 75, probe: 75), -3.0, accuracy: 0.35)
    }

    func testBiquad150HzCutoffIsMinus3dB() {
        XCTAssertEqual(hpfGain(cutoff: 150, probe: 150), -3.0, accuracy: 0.35)
    }

    func testBiquadPassbandIsUnity() {
        XCTAssertEqual(hpfGain(cutoff: 75, probe: 1_000), 0.0, accuracy: 0.25)
        XCTAssertEqual(hpfGain(cutoff: 150, probe: 1_200), 0.0, accuracy: 0.25)
    }

    func testBiquadRolloffOneOctaveBelowCutoff() {
        XCTAssertLessThan(hpfGain(cutoff: 75, probe: 37.5), -10.0)
        XCTAssertLessThan(hpfGain(cutoff: 150, probe: 75), -10.0)
    }

    func testBiquadWhiteNoiseStability() {
        var b = oc_biquad()
        oc_biquad_set_highpass(&b, Double(sr), 75, 0.70710678)
        let y = process(&b, SignalGenerator.whiteNoise(count: Int(sr * 10), amplitude: 0.5))
        XCTAssertTrue(y.allSatisfy { $0.isFinite && abs($0) < 4 })
    }

    func testSmoothedParamBoundsPerSampleDelta() {
        var p = oc_smoothed_param()
        oc_smoothed_param_init(&p, Double(sr), 20, 0)
        oc_smoothed_param_set_target(&p, 1)
        var previous = Float(0)
        var maxStep = Float(0)
        for _ in 0..<Int(sr * 0.1) {
            let value = oc_smoothed_param_next(&p)
            maxStep = max(maxStep, abs(value - previous))
            previous = value
        }
        XCTAssertLessThan(maxStep, 0.002)
    }

    func testSmoothedParamConverges() {
        var p = oc_smoothed_param()
        oc_smoothed_param_init(&p, Double(sr), 20, 0)
        oc_smoothed_param_set_target(&p, 1)
        var value = Float(0)
        for _ in 0..<Int(sr) { value = oc_smoothed_param_next(&p) }
        XCTAssertEqual(value, 1, accuracy: 0.0001)
    }

    func testSmoothedParamSettles() {
        var p = oc_smoothed_param()
        oc_smoothed_param_init(&p, Double(sr), 20, 0)
        oc_smoothed_param_set_target(&p, 1)
        for _ in 0..<Int(sr) { _ = oc_smoothed_param_next(&p) }
        XCTAssertEqual(oc_smoothed_param_is_settled(&p), 1)
    }

    func testGateStaysClosedBelowThreshold() {
        var g = oc_gate()
        oc_gate_init(&g, Double(sr))
        oc_gate_configure(&g, -30, 10, 5, 50, 6)
        for _ in 0..<4_000 { _ = oc_gate_process_sample(&g, Analysis.linear(-45)) }
        XCTAssertEqual(oc_gate_current_state(&g), OC_GATE_CLOSED)
        XCTAssertLessThan(oc_gate_gain_reduction_db(&g), -80)
    }

    func testGateOpensAboveThreshold() {
        var g = oc_gate()
        oc_gate_init(&g, Double(sr))
        oc_gate_configure(&g, -30, 10, 5, 50, 6)
        for _ in 0..<Int(sr * 0.1) { _ = oc_gate_process_sample(&g, Analysis.linear(-12)) }
        XCTAssertTrue(oc_gate_current_state(&g) == OC_GATE_OPEN || oc_gate_current_state(&g) == OC_GATE_ATTACKING)
        XCTAssertGreaterThan(oc_gate_gain_reduction_db(&g), -0.2)
    }

    func testGateMeasuredAttackTime() {
        var g = oc_gate()
        oc_gate_init(&g, Double(sr))
        oc_gate_configure(&g, -30, 10, 5, 50, 6)
        var crossed = -1
        for i in 0..<Int(sr) {
            let y = oc_gate_process_sample(&g, 0.2)
            if crossed < 0 && y / 0.2 > 0.63 { crossed = i }
        }
        XCTAssertEqual(Float(crossed) / sr, 0.010, accuracy: 0.006)
    }

    func testGateMeasuredReleaseTime() {
        var g = oc_gate()
        oc_gate_init(&g, Double(sr))
        oc_gate_configure(&g, -30, 10, 5, 50, 6)
        for _ in 0..<Int(sr * 0.2) { _ = oc_gate_process_sample(&g, 0.2) }
        var crossed = -1
        for i in 0..<Int(sr) {
            let y = oc_gate_process_sample(&g, 0.001)
            if i > Int(0.005 * sr), crossed < 0, y / 0.001 < 0.37 { crossed = i }
        }
        XCTAssertEqual(Float(crossed) / sr, 0.055, accuracy: 0.025)
    }

    func testGateHysteresisPreventsChatter() {
        var g = oc_gate()
        oc_gate_init(&g, Double(sr))
        oc_gate_configure(&g, -30, 2, 0, 20, 6)
        var transitions = 0
        var previous = oc_gate_current_state(&g)
        for i in 0..<20_000 {
            let db: Float = i % 2 == 0 ? -31 : -32
            _ = oc_gate_process_sample(&g, Analysis.linear(db))
            let state = oc_gate_current_state(&g)
            if state != previous {
                transitions += 1
                previous = state
            }
        }
        XCTAssertLessThanOrEqual(transitions, 1)
    }

    func testGateHoldTimeIsHonoured() {
        var g = oc_gate()
        oc_gate_init(&g, Double(sr))
        oc_gate_configure(&g, -30, 1, 40, 20, 6)
        for _ in 0..<Int(sr * 0.05) { _ = oc_gate_process_sample(&g, 0.2) }
        var releaseStarted = -1
        for i in 0..<Int(sr * 0.2) {
            _ = oc_gate_process_sample(&g, 0.001)
            if releaseStarted < 0 && oc_gate_current_state(&g) == OC_GATE_RELEASING { releaseStarted = i }
        }
        XCTAssertEqual(Float(releaseStarted) / sr, 0.040, accuracy: 0.005)
    }

    func testCompressorStaticCurve() {
        var c = oc_compressor()
        oc_compressor_init(&c, Double(sr))
        oc_compressor_configure(&c, -20, 4, 5, 80, 0, 0, OC_DETECTOR_PEAK)
        XCTAssertEqual(oc_compressor_gain_db_for_level(&c, -30), 0, accuracy: 0.001)
        XCTAssertEqual(oc_compressor_gain_db_for_level(&c, -20), 0, accuracy: 0.001)
        XCTAssertEqual(oc_compressor_gain_db_for_level(&c, -8), -9, accuracy: 0.01)
        XCTAssertEqual(oc_compressor_gain_db_for_level(&c, 0), -15, accuracy: 0.01)
    }

    func testCompressorSoftKneeIsMonotonicAndSmooth() {
        var c = oc_compressor()
        oc_compressor_init(&c, Double(sr))
        oc_compressor_configure(&c, -20, 4, 5, 80, 0, 10, OC_DETECTOR_PEAK)
        var lastOut: Float?
        var lastSlope: Float?
        for db in stride(from: -28 as Float, through: -12 as Float, by: 1) {
            let outLevel = db + oc_compressor_gain_db_for_level(&c, db)
            if let previousOut = lastOut {
                let slope = outLevel - previousOut
                XCTAssertGreaterThanOrEqual(outLevel + 0.001, previousOut)
                if let lastSlope { XCTAssertLessThan(abs(slope - lastSlope), 1.0) }
                lastSlope = slope
            }
            lastOut = outLevel
        }
    }

    func testCompressorMeasuredAttackRelease() {
        var c = oc_compressor()
        oc_compressor_init(&c, Double(sr))
        oc_compressor_configure(&c, -30, 8, 10, 60, 0, 0, OC_DETECTOR_PEAK)
        var attack = -1
        for i in 0..<Int(sr) {
            _ = oc_compressor_process_sample(&c, Analysis.linear(-6))
            if attack < 0 && oc_compressor_gain_reduction_db(&c) < -3 { attack = i }
        }
        XCTAssertEqual(Float(attack) / sr, 0.010, accuracy: 0.010)
        var release = -1
        for i in 0..<Int(sr) {
            _ = oc_compressor_process_sample(&c, 0)
            if release < 0 && oc_compressor_gain_reduction_db(&c) > -1 { release = i }
        }
        XCTAssertEqual(Float(release) / sr, 0.18, accuracy: 0.08)
    }

    func testCompressorRMSDetectorUsesMeanSquareState() {
        var c = oc_compressor()
        oc_compressor_init(&c, Double(sr))
        oc_compressor_configure(&c, -24, 2, 5, 80, 0, 0, OC_DETECTOR_RMS)
        let input = SignalGenerator.sine(frequency: 1_000, sampleRate: sr, count: 48_000, amplitude: 0.5)
        var out = Array(repeating: Float(0), count: input.count)
        input.withUnsafeBufferPointer { ib in
            out.withUnsafeMutableBufferPointer { ob in
                oc_compressor_process_block(&c, ib.baseAddress!, ob.baseAddress!, UInt32(input.count))
            }
        }
        XCTAssertTrue(out.allSatisfy { $0.isFinite })
        XCTAssertLessThan(Analysis.rms(out, dropFirst: 24_000), Analysis.rms(input, dropFirst: 24_000))
    }

    func testExciterHarmonicEnergyRisesWithAmount() {
        let input = SignalGenerator.sine(frequency: 4_000, sampleRate: sr, count: 48_000, amplitude: 0.2)
        var low = processExciter(input, amount: 0.2, drive: 2)
        let lowH2 = Analysis.binMagnitude(low, frequency: 8_000, sampleRate: sr)
        low = processExciter(input, amount: 0.8, drive: 2)
        let highH2 = Analysis.binMagnitude(low, frequency: 8_000, sampleRate: sr)
        XCTAssertGreaterThan(highH2, lowH2 * 2)
    }

    func testExciterZeroAmountIsDry() {
        let input = SignalGenerator.sine(frequency: 4_000, sampleRate: sr, count: 48_000, amplitude: 0.2)
        let dry = processExciter(input, amount: 0, drive: 2)
        XCTAssertLessThan(zip(input, dry).map { abs($0 - $1) }.max()!, 1.0e-7)
    }

    func testExciterHasNoDcOffset() {
        let input = SignalGenerator.sine(frequency: 4_000, sampleRate: sr, count: 48_000, amplitude: 0.2)
        let wet = processExciter(input, amount: 0.8, drive: 2)
        XCTAssertLessThan(abs(wet.reduce(0, +) / Float(wet.count)), 0.002)
    }

    func testExciterFullScaleOutputIsBounded() {
        let input = SignalGenerator.sine(frequency: 4_000, sampleRate: sr, count: 48_000, amplitude: 1.0)
        let wet = processExciter(input, amount: 1.0, drive: 4.0)
        XCTAssertTrue(wet.allSatisfy { $0.isFinite })
        XCTAssertLessThan(Analysis.peak(wet), 3.0)
    }

    func processExciter(_ input: [Float], amount: Float, drive: Float) -> [Float] {
        var e = oc_exciter()
        oc_exciter_init(&e, Double(sr))
        oc_exciter_configure(&e, amount, 3_000, drive)
        var out = Array(repeating: Float(0), count: input.count)
        input.withUnsafeBufferPointer { ib in
            out.withUnsafeMutableBufferPointer { ob in
                oc_exciter_process_block(&e, ib.baseAddress!, ob.baseAddress!, UInt32(input.count))
            }
        }
        return out
    }

    func testBigBottomAddsLowBandEnergy() {
        let input = zip(
            SignalGenerator.sine(frequency: 80, sampleRate: sr, count: 48_000, amplitude: 0.12),
            SignalGenerator.sine(frequency: 2_000, sampleRate: sr, count: 48_000, amplitude: 0.12)
        ).map(+)
        let dry = processBigBottom(input, amount: 0, drive: 2)
        let wet = processBigBottom(input, amount: 0.8, drive: 2)
        XCTAssertGreaterThan(Analysis.binMagnitude(wet, frequency: 80, sampleRate: sr), Analysis.binMagnitude(dry, frequency: 80, sampleRate: sr))
    }

    func testBigBottomLeavesHighBandMostlyUnchanged() {
        let input = zip(
            SignalGenerator.sine(frequency: 80, sampleRate: sr, count: 48_000, amplitude: 0.12),
            SignalGenerator.sine(frequency: 2_000, sampleRate: sr, count: 48_000, amplitude: 0.12)
        ).map(+)
        let dry = processBigBottom(input, amount: 0, drive: 2)
        let wet = processBigBottom(input, amount: 0.8, drive: 2)
        XCTAssertEqual(
            Analysis.binMagnitude(wet, frequency: 2_000, sampleRate: sr),
            Analysis.binMagnitude(dry, frequency: 2_000, sampleRate: sr),
            accuracy: 0.01)
    }

    func testBigBottomZeroAmountIsDry() {
        let input = SignalGenerator.whiteNoise(count: 4_096, amplitude: 0.1)
        let dry = processBigBottom(input, amount: 0, drive: 2)
        XCTAssertLessThan(zip(input, dry).map { abs($0 - $1) }.max()!, 1.0e-7)
    }

    func processBigBottom(_ input: [Float], amount: Float, drive: Float) -> [Float] {
        var b = oc_big_bottom()
        oc_big_bottom_init(&b, Double(sr))
        oc_big_bottom_configure(&b, amount, 200, drive)
        var out = Array(repeating: Float(0), count: input.count)
        input.withUnsafeBufferPointer { ib in
            out.withUnsafeMutableBufferPointer { ob in
                oc_big_bottom_process_block(&b, ib.baseAddress!, ob.baseAddress!, UInt32(input.count))
            }
        }
        return out
    }

    func testMeterPeakAndRMS() {
        var meter = oc_meter()
        oc_meter_init(&meter, Double(sr), 10)
        let input = SignalGenerator.sine(frequency: 1_000, sampleRate: sr, count: 48_000, amplitude: 0.5)
        input.withUnsafeBufferPointer { ib in oc_meter_process_block(&meter, ib.baseAddress!, UInt32(input.count)) }
        let values = oc_meter_read(&meter)
        XCTAssertEqual(values.peak, 0.5, accuracy: 0.01)
        XCTAssertEqual(values.rms, 0.5 / sqrt(2), accuracy: 0.02)
    }

    func testRingBufferSpscCorrectnessAndWrapAround() {
        var storage = Array(repeating: Float(0), count: 8)
        var rb = oc_ring_buffer()
        XCTAssertEqual(storage.withUnsafeMutableBufferPointer { oc_ring_buffer_init(&rb, $0.baseAddress!, 8) }, 1)
        var a: [Float] = [1, 2, 3, 4, 5, 6]
        XCTAssertEqual(a.withUnsafeBufferPointer { oc_ring_buffer_write(&rb, $0.baseAddress!, 6) }, 6)
        var out = Array(repeating: Float(0), count: 3)
        XCTAssertEqual(out.withUnsafeMutableBufferPointer { oc_ring_buffer_read(&rb, $0.baseAddress!, 3) }, 3)
        XCTAssertEqual(out, [1, 2, 3])
        a = [7, 8, 9, 10, 11]
        XCTAssertEqual(a.withUnsafeBufferPointer { oc_ring_buffer_write(&rb, $0.baseAddress!, 5) }, 5)
        out = Array(repeating: 0, count: 8)
        let n = out.withUnsafeMutableBufferPointer { oc_ring_buffer_read(&rb, $0.baseAddress!, 8) }
        XCTAssertEqual(Array(out.prefix(Int(n))), [4, 5, 6, 7, 8, 9, 10, 11])
    }

    func testRingBufferFillAccountingAndPartialInterleaving() {
        var storage = Array(repeating: Float(0), count: 4)
        var rb = oc_ring_buffer()
        XCTAssertEqual(storage.withUnsafeMutableBufferPointer { oc_ring_buffer_init(&rb, $0.baseAddress!, 4) }, 1)
        var input: [Float] = [1, 2, 3]
        XCTAssertEqual(input.withUnsafeBufferPointer { oc_ring_buffer_write(&rb, $0.baseAddress!, 3) }, 3)
        XCTAssertEqual(oc_ring_buffer_fill_level(&rb), 3)
        XCTAssertEqual(oc_ring_buffer_available_write(&rb), 1)
        var out = Array(repeating: Float(0), count: 2)
        XCTAssertEqual(out.withUnsafeMutableBufferPointer { oc_ring_buffer_read(&rb, $0.baseAddress!, 2) }, 2)
        input = [4, 5, 6]
        XCTAssertEqual(input.withUnsafeBufferPointer { oc_ring_buffer_write(&rb, $0.baseAddress!, 3) }, 3)
        out = Array(repeating: 0, count: 4)
        XCTAssertEqual(out.withUnsafeMutableBufferPointer { oc_ring_buffer_read(&rb, $0.baseAddress!, 4) }, 4)
        XCTAssertEqual(out, [3, 4, 5, 6])
    }

    func testResamplerRatioOneTracksInput() {
        let input = SignalGenerator.sine(frequency: 1_000, sampleRate: sr, count: 10_000, amplitude: 0.5)
        var r = oc_resampler()
        oc_resampler_init(&r, 1.0)
        var out = Array(repeating: Float(0), count: input.count)
        let cap = UInt32(out.count)
        let n = input.withUnsafeBufferPointer { ib in
            out.withUnsafeMutableBufferPointer { ob in
                oc_resampler_process(&r, ib.baseAddress!, UInt32(input.count), ob.baseAddress!, cap)
            }
        }
        XCTAssertGreaterThan(n, 9_900)
        for i in 0..<1_000 { XCTAssertEqual(out[i], input[i], accuracy: 1.0e-5) }
    }

    func testResamplerSmallPpmSineHasLowThdAndExpectedLength() {
        let input = SignalGenerator.sine(frequency: 1_000, sampleRate: sr, count: 10_000, amplitude: 0.5)
        var r = oc_resampler()
        oc_resampler_init(&r, 1.00005)
        var out = Array(repeating: Float(0), count: input.count)
        let cap = UInt32(out.count)
        let n = input.withUnsafeBufferPointer { ib in
            out.withUnsafeMutableBufferPointer { ob in
                oc_resampler_process(&r, ib.baseAddress!, UInt32(input.count), ob.baseAddress!, cap)
            }
        }
        XCTAssertEqual(Int(n), Int(Double(input.count - 2) / 1.00005), accuracy: 2)
        let tail = Array(out.prefix(Int(n)).suffix(8192))
        XCTAssertLessThan(Analysis.thd(tail, fundamental: 1_000, sampleRate: sr), 0.05)
    }

    func testResamplerBackToBackBlocksAreContinuous() {
        let input = SignalGenerator.sine(frequency: 1_000, sampleRate: sr, count: 4_096, amplitude: 0.5)
        var r = oc_resampler()
        oc_resampler_init(&r, 1.0)
        var output: [Float] = []
        for start in stride(from: 0, to: input.count, by: 128) {
            let block = Array(input[start..<min(input.count, start + 128)])
            var outBlock = Array(repeating: Float(0), count: block.count + 4)
            let cap = UInt32(outBlock.count)
            let n = block.withUnsafeBufferPointer { ib in
                outBlock.withUnsafeMutableBufferPointer { ob in
                    oc_resampler_process(&r, ib.baseAddress!, UInt32(block.count), ob.baseAddress!, cap)
                }
            }
            output.append(contentsOf: outBlock.prefix(Int(n)))
        }
        XCTAssertGreaterThan(output.count, input.count - 4)
        for i in 0..<(input.count - 4) { XCTAssertEqual(output[i], input[i], accuracy: 1.0e-5) }
    }



    func testPullResamplerProducesExactFramesWhenFed() {
        let input = SignalGenerator.sine(frequency: 1_000, sampleRate: sr, count: 1_024, amplitude: 0.5)
        var storage = Array(repeating: Float(0), count: 2_048)
        var ring = oc_ring_buffer()
        XCTAssertEqual(storage.withUnsafeMutableBufferPointer { oc_ring_buffer_init(&ring, $0.baseAddress!, 2_048) }, 1)
        _ = input.withUnsafeBufferPointer { oc_ring_buffer_write(&ring, $0.baseAddress!, UInt32(input.count)) }
        var r = oc_resampler()
        oc_resampler_init(&r, 1.0)
        var out = Array(repeating: Float(0), count: 256)
        let requested = UInt32(out.count)
        let produced = out.withUnsafeMutableBufferPointer { ob in
            oc_resampler_pull(&r, &ring, ob.baseAddress!, requested)
        }
        XCTAssertEqual(produced, 256)
        XCTAssertEqual(oc_resampler_underrun_count(&r), 0)
        for i in 0..<256 { XCTAssertEqual(out[i], input[i], accuracy: 1.0e-5) }
    }

    func testPullResamplerUnderrunZeroFillsAndResets() {
        var storage = Array(repeating: Float(0), count: 8)
        var ring = oc_ring_buffer()
        XCTAssertEqual(storage.withUnsafeMutableBufferPointer { oc_ring_buffer_init(&ring, $0.baseAddress!, 8) }, 1)
        let input: [Float] = [0.1, 0.2]
        _ = input.withUnsafeBufferPointer { oc_ring_buffer_write(&ring, $0.baseAddress!, UInt32(input.count)) }
        var r = oc_resampler()
        oc_resampler_init(&r, 1.0)
        var out = Array(repeating: Float(1), count: 16)
        let requested = UInt32(out.count)
        let produced = out.withUnsafeMutableBufferPointer { ob in
            oc_resampler_pull(&r, &ring, ob.baseAddress!, requested)
        }
        XCTAssertEqual(produced, 0)
        XCTAssertEqual(oc_resampler_underrun_count(&r), 1)
        XCTAssertTrue(out.allSatisfy { $0 == 0 })
        oc_resampler_reset(&r)
        XCTAssertEqual(oc_resampler_underrun_count(&r), 0)
    }

    func testPullResamplerBackToBackBlocksAreContinuous() {
        let input = SignalGenerator.sine(frequency: 1_000, sampleRate: sr, count: 4_096, amplitude: 0.5)
        var storage = Array(repeating: Float(0), count: 8_192)
        var ring = oc_ring_buffer()
        XCTAssertEqual(storage.withUnsafeMutableBufferPointer { oc_ring_buffer_init(&ring, $0.baseAddress!, 8_192) }, 1)
        _ = input.withUnsafeBufferPointer { oc_ring_buffer_write(&ring, $0.baseAddress!, UInt32(input.count)) }
        var r = oc_resampler()
        oc_resampler_init(&r, 1.0)
        var output: [Float] = []
        var seamIndices: [Int] = []
        for _ in 0..<31 {
            var block = Array(repeating: Float(0), count: 128)
            let requested = UInt32(block.count)
            let produced = block.withUnsafeMutableBufferPointer { ob in
                oc_resampler_pull(&r, &ring, ob.baseAddress!, requested)
            }
            XCTAssertEqual(produced, 128)
            seamIndices.append(output.count)
            output.append(contentsOf: block)
        }
        XCTAssertEqual(oc_resampler_underrun_count(&r), 0)
        for i in 0..<output.count { XCTAssertEqual(output[i], input[i], accuracy: 1.0e-5) }
        for seam in seamIndices where seam > 0 && seam < output.count {
            let actualDelta = output[seam] - output[seam - 1]
            let expectedDelta = input[seam] - input[seam - 1]
            XCTAssertEqual(actualDelta, expectedDelta, accuracy: 1.0e-5)
        }
    }

    func testDriftControllerConvergesFromAboveAndBelow() {
        var d = oc_drift_controller()
        oc_drift_controller_init(&d, 500, 0.00001, 0.000001, 0.003, 0.005, 0.0002)
        var fill = Float(900)
        for _ in 0..<1000 { fill -= (oc_drift_controller_update(&d, fill) - 1) * 5_000 }
        XCTAssertEqual(fill, 500, accuracy: 10)
        oc_drift_controller_init(&d, 500, 0.00001, 0.000001, 0.003, 0.005, 0.0002)
        fill = 100
        for _ in 0..<1000 { fill -= (oc_drift_controller_update(&d, fill) - 1) * 5_000 }
        XCTAssertEqual(fill, 500, accuracy: 10)
    }

    func testDriftControllerClampSlewAndAntiWindup() {
        var d = oc_drift_controller()
        oc_drift_controller_init(&d, 500, 0.01, 0.01, 0.002, 0.005, 0.0002)
        let first = oc_drift_controller_update(&d, 10_000)
        XCTAssertLessThanOrEqual(abs(first - 1), 0.00021)
        for _ in 0..<10_000 { _ = oc_drift_controller_update(&d, 10_000) }
        XCTAssertLessThanOrEqual(abs(oc_drift_controller_current_ratio(&d) - 1), 0.0051)
        XCTAssertLessThanOrEqual(abs(d.integrator), 0.0021)
    }

    func testParamQueueFifoOverflowAndNoCorruption() {
        var events = Array(repeating: oc_param_event(), count: 4)
        var q = oc_param_queue()
        XCTAssertEqual(events.withUnsafeMutableBufferPointer { oc_param_queue_init(&q, $0.baseAddress!, 4) }, 1)
        for i in 0..<5 { _ = oc_param_queue_push(&q, UInt32(i), Float(i) * 0.5) }
        XCTAssertEqual(oc_param_queue_dropped_count(&q), 1)
        for i in 0..<4 {
            var ev = oc_param_event()
            XCTAssertEqual(oc_param_queue_pop(&q, &ev), 1)
            XCTAssertEqual(ev.param_id, UInt32(i))
            XCTAssertEqual(ev.value, Float(i) * 0.5)
        }
        var ev = oc_param_event()
        XCTAssertEqual(oc_param_queue_pop(&q, &ev), 0)
    }

    func testChannelStripSilenceBypassedIsExactSilence() {
        var strip = oc_channel_strip()
        oc_channel_strip_init(&strip, Double(sr))
        oc_channel_strip_set_bypasses(&strip, 1, 1, 1, 1)
        let silence = SignalGenerator.silence(count: 512)
        var out = Array(repeating: Float(1), count: silence.count)
        silence.withUnsafeBufferPointer { ib in
            out.withUnsafeMutableBufferPointer { ob in
                oc_channel_strip_process(&strip, ib.baseAddress!, ob.baseAddress!, UInt32(silence.count))
            }
        }
        XCTAssertTrue(out.allSatisfy { $0 == 0 })
    }

    func testChannelStripBypassedIsUnityGain() {
        var strip = oc_channel_strip()
        oc_channel_strip_init(&strip, Double(sr))
        oc_channel_strip_set_bypasses(&strip, 1, 1, 1, 1)
        let input = SignalGenerator.whiteNoise(count: 1024, amplitude: 0.1)
        var out = Array(repeating: Float(0), count: input.count)
        input.withUnsafeBufferPointer { ib in
            out.withUnsafeMutableBufferPointer { ob in
                oc_channel_strip_process(&strip, ib.baseAddress!, ob.baseAddress!, UInt32(input.count))
            }
        }
        XCTAssertLessThan(zip(input, out).map { abs($0 - $1) }.max()!, 1.0e-6)
    }

    func testChannelStripWhiteNoiseHasNoNanInf() {
        var strip = oc_channel_strip()
        oc_channel_strip_init(&strip, Double(sr))
        oc_channel_strip_set_bypasses(&strip, 1, 1, 1, 1)
        let input = SignalGenerator.whiteNoise(count: 4096, amplitude: 0.5)
        var out = Array(repeating: Float(0), count: input.count)
        input.withUnsafeBufferPointer { ib in
            out.withUnsafeMutableBufferPointer { ob in
                oc_channel_strip_process(&strip, ib.baseAddress!, ob.baseAddress!, UInt32(input.count))
            }
        }
        XCTAssertTrue(out.allSatisfy { $0.isFinite })
    }

    func testChannelStripFullChainRealtimeSmoke() {
        var strip = oc_channel_strip()
        oc_channel_strip_init(&strip, Double(sr))
        oc_channel_strip_set_bypasses(&strip, 0, 0, 0, 0)
        oc_channel_strip_set_hpf(&strip, OC_HPF_75, 75)
        let block = SignalGenerator.whiteNoise(count: 128, amplitude: 0.05)
        var out = Array(repeating: Float(0), count: block.count)
        for _ in 0..<20_000 {
            block.withUnsafeBufferPointer { ib in
                out.withUnsafeMutableBufferPointer { ob in
                    oc_channel_strip_process(&strip, ib.baseAddress!, ob.baseAddress!, UInt32(block.count))
                }
            }
            XCTAssertTrue(out.allSatisfy { $0.isFinite && abs($0) < 8 })
        }
    }

    // A bypassed stage must report zero gain reduction. An untouched gate
    // initialises its reduction to -120 dB (fully closed), so if bypass were
    // ignored a disabled gate would peg its meter at full deflection.
    func testBypassedStagesReportNoGainReduction() {
        var strip = oc_channel_strip()
        oc_channel_strip_init(&strip, Double(sr))
        oc_channel_strip_set_bypasses(&strip, 1, 1, 1, 1)

        XCTAssertEqual(oc_channel_strip_gate_gr_db(&strip), 0, "bypassed gate must report no reduction")
        XCTAssertEqual(oc_channel_strip_comp_gr_db(&strip), 0, "bypassed compressor must report no reduction")

        // Run loud audio through the enabled stages so they actually engage,
        // then bypass again and confirm the stale value is not reported.
        oc_channel_strip_set_bypasses(&strip, 0, 0, 1, 1)
        oc_compressor_configure(&strip.compressor, -40, 8, 1, 50, 0, 6, OC_DETECTOR_PEAK)
        let loud = (0..<4800).map { 0.9 * sin(2 * Float.pi * 220 * Float($0) / sr) }
        var out = Array(repeating: Float(0), count: loud.count)
        loud.withUnsafeBufferPointer { ib in
            out.withUnsafeMutableBufferPointer { ob in
                oc_channel_strip_process(&strip, ib.baseAddress!, ob.baseAddress!, UInt32(loud.count))
            }
        }
        XCTAssertLessThan(oc_channel_strip_comp_gr_db(&strip), 0, "engaged compressor should show negative-going reduction")

        oc_channel_strip_set_bypasses(&strip, 1, 1, 1, 1)
        XCTAssertEqual(oc_channel_strip_gate_gr_db(&strip), 0)
        XCTAssertEqual(oc_channel_strip_comp_gr_db(&strip), 0)
    }
}
