import Darwin
import XCTest
import OpenConnctDSP

private let perfSampleRate = 48_000.0
private let perfRingCapacity: UInt32 = 32_768
private let perfTargetFill: Float = 1_536

private func perfUptimeNanos() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

private func configureBenchmarkStrip(_ strip: inout oc_channel_strip, bypassed: Bool) {
    oc_channel_strip_set_pad_db(&strip, 0)
    oc_channel_strip_set_gain_db(&strip, 0)
    if bypassed {
        oc_channel_strip_set_hpf(&strip, OC_HPF_OFF, 75)
        oc_channel_strip_set_bypasses(&strip, 1, 1, 1, 1)
    } else {
        oc_channel_strip_set_hpf(&strip, OC_HPF_75, 75)
        oc_gate_configure(&strip.gate, -60, 2, 80, 150, 6, -60)
        oc_compressor_configure(&strip.compressor, -18, 3, 10, 120, 0, 6, OC_DETECTOR_RMS)
        oc_exciter_configure(&strip.exciter, 0.35, 3_500, 0.5)
        oc_bass_enhancer_configure(&strip.bass_enhancer, 0.35, 120, 0.5)
        oc_channel_strip_set_bypasses(&strip, 0, 0, 0, 0)
    }
}

private final class BenchmarkChannel {
    let blockSize: Int
    let ringStorage: UnsafeMutablePointer<Float>
    let input: UnsafeMutablePointer<Float>
    let pulled: UnsafeMutablePointer<Float>
    let processed: UnsafeMutablePointer<Float>
    var ring = oc_ring_buffer()
    var resampler = oc_resampler()
    var drift = oc_drift_controller()
    var strip = oc_channel_strip()

    init(blockSize: Int, bypassed: Bool) {
        self.blockSize = blockSize
        ringStorage = UnsafeMutablePointer<Float>.allocate(capacity: Int(perfRingCapacity))
        ringStorage.initialize(repeating: 0, count: Int(perfRingCapacity))
        input = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        input.initialize(repeating: 0, count: blockSize)
        pulled = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        pulled.initialize(repeating: 0, count: blockSize)
        processed = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        processed.initialize(repeating: 0, count: blockSize)

        for i in 0..<blockSize {
            input[i] = 0.2 * Float(sin(2.0 * Double.pi * 1_000.0 * Double(i) / perfSampleRate))
        }

        XCTAssertEqual(oc_ring_buffer_init(&ring, ringStorage, perfRingCapacity), 1)
        oc_resampler_init(&resampler, 1)
        oc_drift_controller_init(&drift, perfTargetFill, 2.0e-7, 4.0e-9, 5.0e-4, 1.0e-3, 2.0e-6)
        oc_channel_strip_init(&strip, perfSampleRate)
        configureBenchmarkStrip(&strip, bypassed: bypassed)

        let initialFill = max(4, Int(perfTargetFill) - blockSize)
        var remaining = initialFill
        while remaining > 0 {
            let n = min(remaining, blockSize)
            _ = oc_ring_buffer_write(&ring, input, UInt32(n))
            remaining -= n
        }
    }

    deinit {
        ringStorage.deinitialize(count: Int(perfRingCapacity))
        ringStorage.deallocate()
        input.deinitialize(count: blockSize)
        input.deallocate()
        pulled.deinitialize(count: blockSize)
        pulled.deallocate()
        processed.deinitialize(count: blockSize)
        processed.deallocate()
    }

    func pullOnly() {
        _ = oc_ring_buffer_write(&ring, input, UInt32(blockSize))
        let correction = oc_drift_controller_update(&drift, Float(oc_ring_buffer_fill_level(&ring)))
        oc_resampler_set_ratio(&resampler, Double(correction))
        _ = oc_resampler_pull(&resampler, &ring, pulled, UInt32(blockSize))
    }

    func processFull(into mix: UnsafeMutablePointer<Float>) {
        pullOnly()
        oc_channel_strip_process(&strip, pulled, processed, UInt32(blockSize))
        for i in 0..<blockSize {
            mix[i] += processed[i]
        }
    }
}

final class PerformanceTests: XCTestCase {
    func testTwoChannelFullChainCPUForProductionBlockSizes() {
        for blockSize in [128, 256, 512] {
            let cpu = measureTwoChannelFullChain(blockSize: blockSize, bypassed: false)
            print("[Performance] two-channel full chain block \(blockSize): \(String(format: "%.3f", cpu * 100))% of one core")
            #if DEBUG
            XCTAssertLessThan(cpu, 1.0)
            #else
            XCTAssertLessThan(cpu, 0.05)
            #endif
        }
    }

    func testTwoChannelBypassedChainCPUForAttribution() {
        for blockSize in [128, 256, 512] {
            let cpu = measureTwoChannelFullChain(blockSize: blockSize, bypassed: true)
            print("[Performance] two-channel bypassed chain block \(blockSize): \(String(format: "%.3f", cpu * 100))% of one core")
            XCTAssertLessThan(cpu, 1.0)
        }
    }

    func testTwoChannelResamplerPullCPUForAttribution() {
        for blockSize in [128, 256, 512] {
            let cpu = measureTwoChannelResamplerOnly(blockSize: blockSize)
            print("[Performance] two-channel resampler pull block \(blockSize): \(String(format: "%.3f", cpu * 100))% of one core")
            XCTAssertLessThan(cpu, 0.25)
        }
    }

    private func measureTwoChannelFullChain(blockSize: Int, bypassed: Bool) -> Double {
        let left = BenchmarkChannel(blockSize: blockSize, bypassed: bypassed)
        let right = BenchmarkChannel(blockSize: blockSize, bypassed: bypassed)
        let mix = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        mix.initialize(repeating: 0, count: blockSize)
        defer {
            mix.deinitialize(count: blockSize)
            mix.deallocate()
        }

        for _ in 0..<1_000 {
            renderPair(left: left, right: right, mix: mix, blockSize: blockSize)
        }

        #if DEBUG
        let audioSeconds = 3.0
        #else
        let audioSeconds = 30.0
        #endif
        let blocks = Int(audioSeconds * perfSampleRate / Double(blockSize))
        let start = perfUptimeNanos()
        for _ in 0..<blocks {
            renderPair(left: left, right: right, mix: mix, blockSize: blockSize)
        }
        let elapsed = Double(perfUptimeNanos() - start) / 1.0e9
        return elapsed / (Double(blocks * blockSize) / perfSampleRate)
    }

    private func measureTwoChannelResamplerOnly(blockSize: Int) -> Double {
        let left = BenchmarkChannel(blockSize: blockSize, bypassed: true)
        let right = BenchmarkChannel(blockSize: blockSize, bypassed: true)
        for _ in 0..<1_000 {
            left.pullOnly()
            right.pullOnly()
        }

        #if DEBUG
        let audioSeconds = 3.0
        #else
        let audioSeconds = 30.0
        #endif
        let blocks = Int(audioSeconds * perfSampleRate / Double(blockSize))
        let start = perfUptimeNanos()
        for _ in 0..<blocks {
            left.pullOnly()
            right.pullOnly()
        }
        let elapsed = Double(perfUptimeNanos() - start) / 1.0e9
        return elapsed / (Double(blocks * blockSize) / perfSampleRate)
    }

    private func renderPair(
        left: BenchmarkChannel,
        right: BenchmarkChannel,
        mix: UnsafeMutablePointer<Float>,
        blockSize: Int
    ) {
        for i in 0..<blockSize { mix[i] = 0 }
        left.processFull(into: mix)
        right.processFull(into: mix)
    }
}
