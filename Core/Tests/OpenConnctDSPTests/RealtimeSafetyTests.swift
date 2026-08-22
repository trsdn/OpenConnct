import Darwin
import XCTest
import OpenConnctDSP

private let rtSampleRate = 48_000.0
private let rtRingCapacity: UInt32 = 32_768
private let rtTargetFill: Float = 1_536
private let rtKp: Float = 2.0e-7
private let rtKi: Float = 4.0e-9
private let rtIntegratorLimit: Float = 5.0e-4
private let rtRatioLimit: Float = 1.0e-3
private let rtSlewPerUpdate: Float = 2.0e-6

private func uptimeNanos() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

private func mallocBlocksInUse() -> UInt64 {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(malloc_default_zone(), &stats)
    return UInt64(stats.blocks_in_use)
}

private func configureProductionLikeEffects(_ strip: inout oc_channel_strip, bypassed: Bool = false) {
    oc_channel_strip_set_pad_db(&strip, 0)
    oc_channel_strip_set_gain_db(&strip, 0)
    oc_channel_strip_set_hpf(&strip, OC_HPF_75, 75)
    oc_gate_configure(&strip.gate, -60, 2, 80, 150, 6, -60)
    oc_compressor_configure(&strip.compressor, -18, 3, 10, 120, 0, 6, OC_DETECTOR_RMS)
    oc_exciter_configure(&strip.exciter, 0.35, 3_500, 0.5)
    oc_bass_enhancer_configure(&strip.bass_enhancer, 0.35, 120, 0.5)
    oc_channel_strip_set_bypasses(&strip, bypassed ? 1 : 0, bypassed ? 1 : 0, bypassed ? 1 : 0, bypassed ? 1 : 0)
}

private final class RealtimeRenderFixture {
    let blockSize: Int
    let ringStorage: UnsafeMutablePointer<Float>
    let input: UnsafeMutablePointer<Float>
    let pulled: UnsafeMutablePointer<Float>
    let processed: UnsafeMutablePointer<Float>
    let mix: UnsafeMutablePointer<Float>
    var ring = oc_ring_buffer()
    var resampler = oc_resampler()
    var drift = oc_drift_controller()
    var strip = oc_channel_strip()
    var phase = 0.0
    var maxAbsOutput: Float = 0

    init(blockSize: Int, bypassed: Bool = false) {
        self.blockSize = blockSize
        ringStorage = UnsafeMutablePointer<Float>.allocate(capacity: Int(rtRingCapacity))
        ringStorage.initialize(repeating: 0, count: Int(rtRingCapacity))
        input = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        input.initialize(repeating: 0, count: blockSize)
        pulled = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        pulled.initialize(repeating: 0, count: blockSize)
        processed = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        processed.initialize(repeating: 0, count: blockSize)
        mix = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        mix.initialize(repeating: 0, count: blockSize)

        XCTAssertEqual(oc_ring_buffer_init(&ring, ringStorage, rtRingCapacity), 1)
        oc_resampler_init(&resampler, 1)
        oc_drift_controller_init(&drift, rtTargetFill, rtKp, rtKi, rtIntegratorLimit, rtRatioLimit, rtSlewPerUpdate)
        oc_channel_strip_init(&strip, rtSampleRate)
        configureProductionLikeEffects(&strip, bypassed: bypassed)

        let initialFill = max(4, Int(rtTargetFill) - blockSize)
        for i in 0..<blockSize { input[i] = 0 }
        var remaining = initialFill
        while remaining > 0 {
            let n = min(remaining, blockSize)
            _ = oc_ring_buffer_write(&ring, input, UInt32(n))
            remaining -= n
        }
    }

    deinit {
        ringStorage.deinitialize(count: Int(rtRingCapacity))
        ringStorage.deallocate()
        input.deinitialize(count: blockSize)
        input.deallocate()
        pulled.deinitialize(count: blockSize)
        pulled.deallocate()
        processed.deinitialize(count: blockSize)
        processed.deallocate()
        mix.deinitialize(count: blockSize)
        mix.deallocate()
    }

    func renderSineBlock(amplitude: Float = 0.2, frequency: Double = 1_000) {
        let step = 2.0 * Double.pi * frequency / rtSampleRate
        for i in 0..<blockSize {
            input[i] = amplitude * Float(sin(phase))
            phase += step
            if phase >= 2.0 * Double.pi { phase -= 2.0 * Double.pi }
        }
        renderPreparedInput()
    }

    func renderDecayBlock(_ amplitude: inout Float) {
        for i in 0..<blockSize {
            input[i] = amplitude
            amplitude *= 0.975
        }
        renderPreparedInput()
    }

    private func renderPreparedInput() {
        let written = oc_ring_buffer_write(&ring, input, UInt32(blockSize))
        XCTAssertEqual(written, UInt32(blockSize))

        let fill = Float(oc_ring_buffer_fill_level(&ring))
        let correction = oc_drift_controller_update(&drift, fill)
        oc_resampler_set_ratio(&resampler, Double(correction))
        let produced = oc_resampler_pull(&resampler, &ring, pulled, UInt32(blockSize))
        XCTAssertEqual(produced, UInt32(blockSize))

        oc_channel_strip_process(&strip, pulled, processed, UInt32(blockSize))
        for i in 0..<blockSize {
            let sample = processed[i]
            XCTAssertTrue(sample.isFinite)
            maxAbsOutput = max(maxAbsOutput, abs(sample))
            mix[i] = sample
        }
    }
}

final class RealtimeSafetyTests: XCTestCase {
    func testFullRenderPathIsFiniteBoundedAndAllocationStable() {
        let fixture = RealtimeRenderFixture(blockSize: 256)
        for _ in 0..<1_000 { fixture.renderSineBlock() }

        let beforeBlocks = mallocBlocksInUse()
        for _ in 0..<20_000 { fixture.renderSineBlock() }
        let afterBlocks = mallocBlocksInUse()

        print("[RealtimeSafety] allocation-stability blocks before \(beforeBlocks), after \(afterBlocks), max |sample| \(fixture.maxAbsOutput)")
        XCTAssertLessThanOrEqual(afterBlocks, beforeBlocks + 2)
        XCTAssertLessThan(fixture.maxAbsOutput, 4)
    }

    func testMallocGrowthDetectorCatchesRetainedAllocations() {
        let before = mallocBlocksInUse()
        var allocations: [UnsafeMutableRawPointer] = []
        allocations.reserveCapacity(16)
        for _ in 0..<16 {
            allocations.append(UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 16))
        }
        let after = mallocBlocksInUse()
        allocations.forEach { $0.deallocate() }
        print("[RealtimeSafety] detector self-check blocks before \(before), after deliberate allocations \(after)")
        XCTAssertGreaterThan(after, before)
    }

    func testPerBlockExecutionTimeHasNoPathologicalOutliers() {
        let fixture = RealtimeRenderFixture(blockSize: 256)
        for _ in 0..<1_000 { fixture.renderSineBlock() }

        var times = Array(repeating: UInt64(0), count: 8_000)
        for i in times.indices {
            let start = uptimeNanos()
            fixture.renderSineBlock()
            times[i] = uptimeNanos() - start
        }

        let sorted = times.sorted()
        let median = sorted[sorted.count / 2]
        let maximum = sorted.last ?? 0
        print("[RealtimeSafety] block 256 median \(median) ns, max \(maximum) ns")
        XCTAssertLessThan(maximum, max(median * 1_000, 20_000_000))
    }

    func testDenormalTailDoesNotCauseProcessingTimeBlowup() {
        let fixture = RealtimeRenderFixture(blockSize: 256)
        var amplitude = Float(1.0e-10)
        var firstHalf = Array(repeating: UInt64(0), count: 1_000)
        var secondHalf = Array(repeating: UInt64(0), count: 1_000)

        for i in firstHalf.indices {
            let start = uptimeNanos()
            fixture.renderDecayBlock(&amplitude)
            firstHalf[i] = uptimeNanos() - start
        }
        for i in secondHalf.indices {
            let start = uptimeNanos()
            fixture.renderDecayBlock(&amplitude)
            secondHalf[i] = uptimeNanos() - start
        }

        let firstMedian = firstHalf.sorted()[firstHalf.count / 2]
        let secondMedian = secondHalf.sorted()[secondHalf.count / 2]
        print("[RealtimeSafety] denormal median first \(firstMedian) ns, tail \(secondMedian) ns")
        XCTAssertLessThan(secondMedian, firstMedian * 20 + 20_000)
    }
}
