// OCBench — offline listening and measurement rig for the channel strip.
//
// Why this exists: every DSP unit test in Core proves a block is mathematically
// what it claims to be — the gate really does close, the compressor really does
// follow its static curve. None of them answer the question that actually
// matters, which is whether the chain sounds good on a real voice in a real
// room. That question cannot be settled by asserting on a sine wave.
//
// So this tool does three things, all against the *same* C++ code the app runs
// at render time, not a reimplementation:
//
//   capture   record a real microphone to a WAV, so we test against the user's
//             own voice and their own room noise rather than synthetic hiss
//   render    push a WAV through oc_channel_strip and write the result, so a
//             before/after pair can be listened to back to back
//   measure   print the numbers that decide whether a setting is right —
//             noise floor, speech level, the gap between them, and how the
//             energy is distributed across the spectrum
//
// It is packaged as a signed .app for the same reason OCProbe is: TCC keys the
// microphone grant to a code signature and bundle identifier, and a bare
// command-line binary has neither.

import Accelerate
import AudioToolbox
import CoreAudio
import Darwin
import Foundation

// MARK: - WAV

/// Mono float samples plus a sample rate. Everything here is mono: the channel
/// strip is a mono processor and mixing is a separate concern.
struct Audio {
    var samples: [Float]
    var sampleRate: Double
}

struct Err: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

enum WAV {
    /// Reads 16-bit PCM, 24-bit PCM or 32-bit float WAV. Multi-channel input is
    /// folded to mono by averaging, because a USB mic that carries the same
    /// signal on both sides would otherwise skew every level measurement.
    static func read(_ path: String) throws -> Audio {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count > 44, data[0..<4].elementsEqual(Array("RIFF".utf8)),
              data[8..<12].elementsEqual(Array("WAVE".utf8)) else {
            throw Err("not a RIFF/WAVE file: \(path)")
        }

        func u16(_ o: Int) -> UInt16 { UInt16(data[o]) | UInt16(data[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 {
            UInt32(data[o]) | UInt32(data[o + 1]) << 8
                | UInt32(data[o + 2]) << 16 | UInt32(data[o + 3]) << 24
        }

        var pos = 12
        var format: UInt16 = 0, channels: UInt16 = 1, bits: UInt16 = 16
        var rate: Double = 48000
        var pcm: Data? = nil

        while pos + 8 <= data.count {
            let id = String(decoding: data[pos..<pos + 4], as: UTF8.self)
            let size = Int(u32(pos + 4))
            let body = pos + 8
            if id == "fmt ", body + 16 <= data.count {
                format = u16(body)
                channels = max(1, u16(body + 2))
                rate = Double(u32(body + 4))
                bits = u16(body + 14)
            } else if id == "data" {
                pcm = data.subdata(in: body..<min(data.count, body + size))
            }
            pos = body + size + (size & 1)
        }

        guard let raw = pcm else { throw Err("no data chunk in \(path)") }
        var interleaved: [Float]

        if format == 3, bits == 32 {
            interleaved = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        } else if format == 1, bits == 16 {
            let ints: [Int16] = raw.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            interleaved = ints.map { Float($0) / 32768.0 }
        } else if format == 1, bits == 24 {
            var out = [Float]()
            out.reserveCapacity(raw.count / 3)
            var i = 0
            while i + 2 < raw.count {
                let v = Int32(raw[i]) | Int32(raw[i + 1]) << 8
                    | Int32(Int8(bitPattern: raw[i + 2])) << 16
                out.append(Float(v) / 8_388_608.0)
                i += 3
            }
            interleaved = out
        } else {
            throw Err("unsupported WAV: format=\(format) bits=\(bits)")
        }

        let ch = Int(channels)
        guard ch > 1 else { return Audio(samples: interleaved, sampleRate: rate) }
        let frames = interleaved.count / ch
        var mono = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var acc: Float = 0
            for c in 0..<ch { acc += interleaved[f * ch + c] }
            mono[f] = acc / Float(ch)
        }
        return Audio(samples: mono, sampleRate: rate)
    }

    /// Writes 16-bit PCM. Float WAVs are more faithful but several macOS players
    /// refuse them, and the entire point of the output is that a human can
    /// double-click it and listen.
    static func write(_ audio: Audio, to path: String) throws {
        var out = Data()
        let byteCount = audio.samples.count * 2

        func a32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func a16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }

        out.append(contentsOf: Array("RIFF".utf8)); a32(UInt32(36 + byteCount))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8)); a32(16)
        a16(1); a16(1)
        a32(UInt32(audio.sampleRate)); a32(UInt32(audio.sampleRate) * 2)
        a16(2); a16(16)
        out.append(contentsOf: Array("data".utf8)); a32(UInt32(byteCount))

        for s in audio.samples {
            a16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767)))
        }
        try out.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Measurement

func dbfs(_ linear: Float) -> Float { linear <= 1e-12 ? -120 : 20 * log10(linear) }

/// Block RMS in dBFS, one value per `windowMS`. Everything else derives from
/// this: percentiles over these blocks separate "the room when nobody is
/// talking" from "the room when somebody is".
func blockLevels(_ a: Audio, windowMS: Double = 20) -> [Float] {
    let n = max(1, Int(a.sampleRate * windowMS / 1000))
    var out: [Float] = []
    out.reserveCapacity(a.samples.count / n)
    var i = 0
    a.samples.withUnsafeBufferPointer { p in
        while i + n <= a.samples.count {
            var ms: Float = 0
            vDSP_measqv(p.baseAddress! + i, 1, &ms, vDSP_Length(n))
            out.append(dbfs(sqrt(ms)))
            i += n
        }
    }
    return out
}

func percentile(_ sorted: [Float], _ p: Double) -> Float {
    guard !sorted.isEmpty else { return -120 }
    return sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))]
}

/// Energy in three broad bands as a fraction of the total. Coarse on purpose:
/// the question is only ever "did the exciter add top" or "did Bass Enhancer add
/// weight", and a third-octave analysis would bury that in detail.
func bandEnergy(_ a: Audio) -> (sub: Double, low: Double, mid: Double, high: Double) {
    let log2n = vDSP_Length(11)
    let n = 1 << Int(log2n)
    guard a.samples.count >= n,
          let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return (0, 0, 0, 0) }
    defer { vDSP_destroy_fftsetup(setup) }

    var window = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

    var acc = [Double](repeating: 0, count: n / 2)
    var real = [Float](repeating: 0, count: n / 2)
    var imag = [Float](repeating: 0, count: n / 2)
    var windowed = [Float](repeating: 0, count: n)
    var mags = [Float](repeating: 0, count: n / 2)

    var offset = 0, windows = 0
    while offset + n <= a.samples.count {
        vDSP_vmul(Array(a.samples[offset..<offset + n]), 1, window, 1, &windowed, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { c in
                        vDSP_ctoz(c, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        for k in 0..<(n / 2) { acc[k] += Double(mags[k]) }
        offset += n
        windows += 1
    }
    guard windows > 0 else { return (0, 0, 0, 0) }

    let binHz = a.sampleRate / Double(n)
    // Bass Enhancer works below ~150 Hz, so a 250 Hz "low" band is too coarse to
    // see it at all. The sub band is reported separately for that reason.
    var sub = 0.0, low = 0.0, mid = 0.0, high = 0.0
    for k in 1..<(n / 2) {
        let hz = Double(k) * binHz
        if hz < 150 { sub += acc[k] } else if hz < 250 { low += acc[k] } else if hz < 3000 { mid += acc[k] } else { high += acc[k] }
    }
    let total = sub + low + mid + high
    guard total > 0 else { return (0, 0, 0, 0) }
    return (sub / total, low / total, mid / total, high / total)
}

struct Report {
    var peakDB: Float
    var rmsDB: Float
    var noiseFloorDB: Float
    var speechDB: Float
    var bands: (sub: Double, low: Double, mid: Double, high: Double)

    /// The distance between a quiet moment and a loud one. The single most
    /// useful number here: a gate is judged by how much it widens this, a
    /// compressor by how much it narrows it.
    var spanDB: Float { speechDB - noiseFloorDB }
}

/// What the dynamics stages actually did, sampled once per render block.
///
/// The level report alone cannot distinguish "the gate never closed" from "the
/// gate closed but there was nothing to remove", and it cannot see gate chatter
/// at all — a gate flapping open and shut inside a pause averages out to a
/// perfectly reasonable-looking noise floor. These are the numbers that catch
/// both.
struct DynamicsTrace {
    var gateClosedFraction: Double = 0
    var gateMaxReductionDB: Float = 0
    var gateTransitions: Int = 0
    var compActiveFraction: Double = 0
    var compMeanReductionDB: Float = 0
    var compMaxReductionDB: Float = 0
    var seconds: Double = 0

    /// Open/shut cycles per second of audio. A gate working properly on speech
    /// moves a handful of times per sentence; double figures per second is
    /// chatter, audible as a stuttering gargle on the noise floor.
    var transitionsPerSecond: Double { seconds > 0 ? Double(gateTransitions) / seconds : 0 }
}

func analyse(_ a: Audio) -> Report {
    var peak: Float = 0, meanSquare: Float = 0
    a.samples.withUnsafeBufferPointer {
        vDSP_maxmgv($0.baseAddress!, 1, &peak, vDSP_Length($0.count))
        vDSP_measqv($0.baseAddress!, 1, &meanSquare, vDSP_Length($0.count))
    }
    let levels = blockLevels(a).sorted()
    return Report(peakDB: dbfs(peak), rmsDB: dbfs(sqrt(meanSquare)),
                  noiseFloorDB: percentile(levels, 0.10),
                  speechDB: percentile(levels, 0.95),
                  bands: bandEnergy(a))
}

func printReport(_ label: String, _ r: Report) {
    let head = label.padding(toLength: max(14, label.count), withPad: " ", startingAt: 0)
    print(String(format: "  %@  peak %7.1f  rms %7.1f  quiet %7.1f  loud %7.1f  span %6.1f  "
                 + "sub %4.1f%% low %3.0f%% mid %3.0f%% high %3.0f%%",
                 head, r.peakDB, r.rmsDB, r.noiseFloorDB, r.speechDB, r.spanDB,
                 r.bands.sub * 100, r.bands.low * 100, r.bands.mid * 100, r.bands.high * 100))
}

// MARK: - Render

struct StripConfig {
    var gain: Float = 0
    var hpf: oc_hpf_mode = OC_HPF_OFF
    var hpfFreq: Float = 100
    var gate: (threshold: Float, attack: Float, hold: Float, release: Float, hysteresis: Float, range: Float)?
    var comp: (threshold: Float, ratio: Float, attack: Float, release: Float, makeup: Float, knee: Float)?
    var exciter: (amount: Float, frequency: Float, drive: Float)?
    var bassEnhancer: (amount: Float, frequency: Float, drive: Float)?
}

/// Runs the audio through the real strip in 128-frame blocks — the same size the
/// engine uses — so smoothing ramps and detector time constants see exactly the
/// cadence they will see live. Rendering the whole file in one call would hide
/// any block-boundary discontinuity.
/// As `render`, but also reports what the gate and compressor did while doing it.
func render(_ input: Audio, _ cfg: StripConfig) -> (audio: Audio, trace: DynamicsTrace) {
    var strip = oc_channel_strip()
    oc_channel_strip_init(&strip, oc_sample_rate(input.sampleRate))
    oc_channel_strip_set_gain_db(&strip, cfg.gain)
    oc_channel_strip_set_hpf(&strip, cfg.hpf, cfg.hpfFreq)
    oc_channel_strip_set_bypasses(&strip,
                                  cfg.gate == nil ? 1 : 0,
                                  cfg.comp == nil ? 1 : 0,
                                  cfg.exciter == nil ? 1 : 0,
                                  cfg.bassEnhancer == nil ? 1 : 0)
    if let g = cfg.gate {
        oc_gate_configure(&strip.gate, g.threshold, g.attack, g.hold, g.release, g.hysteresis, g.range)
    }
    if let c = cfg.comp {
        oc_compressor_configure(&strip.compressor, c.threshold, c.ratio, c.attack,
                                c.release, c.makeup, c.knee, OC_DETECTOR_RMS)
    }
    if let e = cfg.exciter { oc_exciter_configure(&strip.exciter, e.amount, e.frequency, e.drive) }
    if let b = cfg.bassEnhancer { oc_bass_enhancer_configure(&strip.bass_enhancer, b.amount, b.frequency, b.drive) }

    var out = [Float](repeating: 0, count: input.samples.count)
    var trace = DynamicsTrace()
    var blocks = 0, gateClosedBlocks = 0, compBlocks = 0
    var compSum: Float = 0
    var wasClosed = false

    let block = 128
    var i = 0
    input.samples.withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { dst in
            while i < src.count {
                let n = min(block, src.count - i)
                oc_channel_strip_process(&strip, src.baseAddress! + i, dst.baseAddress! + i, UInt32(n))

                let gateGR = oc_channel_strip_gate_gr_db(&strip)
                let compGR = oc_channel_strip_comp_gr_db(&strip)
                // "Closed" means audibly attenuating, not merely non-zero:
                // the gate's smoothing ramp passes through small values on every
                // transition and counting those would report constant activity.
                let closed = gateGR < -1
                if closed { gateClosedBlocks += 1 }
                if closed != wasClosed { trace.gateTransitions += 1; wasClosed = closed }
                trace.gateMaxReductionDB = min(trace.gateMaxReductionDB, gateGR)
                if compGR < -0.5 { compBlocks += 1; compSum += compGR }
                trace.compMaxReductionDB = min(trace.compMaxReductionDB, compGR)

                blocks += 1
                i += n
            }
        }
    }

    if blocks > 0 {
        trace.gateClosedFraction = Double(gateClosedBlocks) / Double(blocks)
        trace.compActiveFraction = Double(compBlocks) / Double(blocks)
    }
    if compBlocks > 0 { trace.compMeanReductionDB = compSum / Float(compBlocks) }
    trace.seconds = Double(input.samples.count) / input.sampleRate
    return (Audio(samples: out, sampleRate: input.sampleRate), trace)
}

func printTrace(_ cfg: StripConfig, _ t: DynamicsTrace) {
    var parts: [String] = []
    if cfg.gate != nil {
        parts.append(String(format: "gate closed %3.0f%% of the time, max %.1f dB, %.1f moves/s",
                            t.gateClosedFraction * 100, t.gateMaxReductionDB, t.transitionsPerSecond))
    }
    if cfg.comp != nil {
        parts.append(String(format: "comp active %3.0f%%, mean %.1f dB, max %.1f dB",
                            t.compActiveFraction * 100, t.compMeanReductionDB, t.compMaxReductionDB))
    }
    for p in parts { print("                  \(p)") }
}

/// Harmonic distortion of a single stage, measured on a pure tone.
///
/// This is the measurement that decides whether the exciter and Bass Enhancer are
/// doing what their names claim. Both are built around `tanh`, and `tanh(u)` is
/// very nearly `u` for small `u` — so a saturator fed a quiet signal produces no
/// harmonics at all and degenerates into a plain shelving EQ. Feeding a tone at
/// several levels and reading the harmonic series back out is the only way to
/// see that, and it cannot be seen in a broadband energy figure.
struct Harmonics {
    var fundamentalDB: Float
    var harmonicDB: [Float]      // 2nd, 3rd, 4th, 5th
    var thdPercent: Double
}

func harmonics(of a: Audio, fundamental: Double) -> Harmonics {
    let log2n = vDSP_Length(15)
    let n = 1 << Int(log2n)
    guard a.samples.count >= n,
          let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
        return Harmonics(fundamentalDB: -120, harmonicDB: [], thdPercent: 0)
    }
    defer { vDSP_destroy_fftsetup(setup) }

    // Take a window from the middle so filter and envelope start-up transients,
    // which are broadband and would masquerade as distortion, are excluded.
    let start = max(0, (a.samples.count - n) / 2)
    var window = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    var windowed = [Float](repeating: 0, count: n)
    vDSP_vmul(Array(a.samples[start..<start + n]), 1, window, 1, &windowed, 1, vDSP_Length(n))

    var real = [Float](repeating: 0, count: n / 2)
    var imag = [Float](repeating: 0, count: n / 2)
    var mags = [Float](repeating: 0, count: n / 2)
    real.withUnsafeMutableBufferPointer { rp in
        imag.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            windowed.withUnsafeBufferPointer { src in
                src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { c in
                    vDSP_ctoz(c, 2, &split, 1, vDSP_Length(n / 2))
                }
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
        }
    }

    let binHz = a.sampleRate / Double(n)
    // Sum a few bins either side: the Hann window spreads a tone across
    // neighbours, and reading a single bin would under-report by several dB.
    func energy(around hz: Double) -> Double {
        let centre = Int((hz / binHz).rounded())
        guard centre > 2, centre + 3 < n / 2 else { return 0 }
        return (centre - 2...centre + 2).reduce(0.0) { $0 + Double(mags[$1]) }
    }

    let f0 = energy(around: fundamental)
    var hs: [Float] = []
    var harmonicSum = 0.0
    for k in 2...5 where fundamental * Double(k) < a.sampleRate / 2 {
        let e = energy(around: fundamental * Double(k))
        harmonicSum += e
        hs.append(f0 > 0 ? Float(10 * log10(max(e, 1e-20) / f0)) : -120)
    }
    return Harmonics(fundamentalDB: Float(10 * log10(max(f0, 1e-20))),
                     harmonicDB: hs,
                     thdPercent: f0 > 0 ? sqrt(harmonicSum / f0) * 100 : 0)
}

func tone(hz: Double, dbfs: Double, seconds: Double, sampleRate: Double = 48000) -> Audio {
    let amp = Float(pow(10, dbfs / 20))
    let count = Int(seconds * sampleRate)
    var s = [Float](repeating: 0, count: count)
    for i in 0..<count { s[i] = amp * sinf(Float(2 * Double.pi * hz * Double(i) / sampleRate)) }
    return Audio(samples: s, sampleRate: sampleRate)
}

// MARK: - Devices

func allDevices() -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
    return ids
}

func deviceName(_ id: AudioObjectID) -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let st = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
    return st == noErr ? (name as String) : ""
}

func hasInput(_ id: AudioObjectID) -> Bool {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                       mScope: kAudioDevicePropertyScopeInput,
                                       mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return false }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, buf) == noErr else { return false }
    let list = buf.assumingMemoryBound(to: AudioBufferList.self)
    return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
}

// MARK: - Capture

final class Capture {
    private var unit: AudioUnit!
    private var list: UnsafeMutableAudioBufferListPointer
    private let channels: Int
    var frames: [Float] = []

    init(device: AudioObjectID, sampleRate: Double) throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw Err("no HAL output unit") }
        var u: AudioUnit? = nil
        guard AudioComponentInstanceNew(comp, &u) == noErr, let unit = u else {
            throw Err("cannot instantiate HAL unit")
        }
        self.unit = unit

        var on: UInt32 = 1, off: UInt32 = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4)
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4)
        var dev = device
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, 4)

        // Ask for non-interleaved float mono and let the unit convert. If the
        // device insists on more channels, mChannelsPerFrame tells us and the
        // callback folds them down.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                             &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        var actual = AudioStreamBasicDescription()
        var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &actual, &sz)
        channels = max(1, Int(actual.mChannelsPerFrame))

        list = AudioBufferList.allocate(maximumBuffers: channels)
        for c in 0..<channels {
            list[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 4 * 8192, mData: malloc(4 * 8192))
        }
        frames.reserveCapacity(Int(sampleRate) * 120)

        var cb = AURenderCallbackStruct(inputProc: { ctx, flags, ts, bus, n, _ in
            Unmanaged<Capture>.fromOpaque(ctx).takeUnretainedValue().pull(flags, ts, bus, n)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                             &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        guard AudioUnitInitialize(unit) == noErr else { throw Err("AudioUnitInitialize failed") }
    }

    private func pull(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                      _ ts: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ n: UInt32) -> OSStatus {
        for c in 0..<channels { list[c].mDataByteSize = 4 * n }
        guard AudioUnitRender(unit, flags, ts, bus, n, list.unsafeMutablePointer) == noErr else {
            return noErr
        }
        // Appending to a Swift array on the IO thread would be forbidden in the
        // product. It is fine here: this is an offline capture tool, not the
        // realtime engine, and a complete recording beats purity. The capacity
        // is reserved up front so the common case does not reallocate.
        let count = Int(n)
        if channels == 1 {
            let p = list[0].mData!.assumingMemoryBound(to: Float.self)
            frames.append(contentsOf: UnsafeBufferPointer(start: p, count: count))
        } else {
            for f in 0..<count {
                var acc: Float = 0
                for c in 0..<channels { acc += list[c].mData!.assumingMemoryBound(to: Float.self)[f] }
                frames.append(acc / Float(channels))
            }
        }
        return noErr
    }

    func start() { AudioOutputUnitStart(unit) }
    func stop() { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit) }
}

// MARK: - CLI

func usage() -> Never {
    print("""
    OCBench — listening and measurement rig for the OpenConnect channel strip

      list
      capture <seconds> <out.wav> [--device <name substring>]
      render  <in.wav> <out.wav> [--gate] [--comp] [--exciter] [--bassenh]
                                 [--hpf 75|150] [--gain <dB>]
      measure <file.wav> [more.wav ...]
      suite   <in.wav> <outdir>     render every stage separately and compare
    """)
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

func flag(_ n: String) -> Bool { args.contains("--\(n)") }
func value(_ n: String) -> String? {
    guard let i = args.firstIndex(of: "--\(n)"), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// The application defaults, mirrored from ChannelSettings.swift. Kept here
/// deliberately rather than read from the app, so a tuning change can be tried
/// out and measured here first and only then moved into the product.
let defaults = StripConfig(
    gate: (threshold: -45, attack: 2, hold: 100, release: 200, hysteresis: 6, range: -60),
    comp: (threshold: -18, ratio: 3, attack: 10, release: 120, makeup: 0, knee: 6),
    exciter: (amount: 0.35, frequency: 3500, drive: 0.5),
    bassEnhancer: (amount: 0.35, frequency: 100, drive: 0.5))

do {
    switch command {
    case "list":
        for id in allDevices() where hasInput(id) { print("  \(id)  \(deviceName(id))") }

    case "capture":
        guard args.count >= 3, let seconds = Double(args[1]) else { usage() }
        let inputs = allDevices().filter { hasInput($0) }
        let picked: AudioObjectID
        if let want = value("device") {
            guard let m = inputs.first(where: { deviceName($0).localizedCaseInsensitiveContains(want) })
            else { throw Err("no input device matching '\(want)'") }
            picked = m
        } else {
            guard let m = inputs.first else { throw Err("no input devices") }
            picked = m
        }
        print("Recording \(seconds)s from: \(deviceName(picked))")
        let cap = try Capture(device: picked, sampleRate: 48000)
        cap.start()
        Thread.sleep(forTimeInterval: seconds)
        cap.stop()
        let audio = Audio(samples: cap.frames, sampleRate: 48000)
        guard !audio.samples.isEmpty else { throw Err("captured nothing — microphone access denied?") }
        try WAV.write(audio, to: args[2])
        print("Wrote \(args[2])  (\(audio.samples.count) frames)")
        printReport("captured", analyse(audio))

    case "render":
        guard args.count >= 3 else { usage() }
        let input = try WAV.read(args[1])
        var cfg = StripConfig()
        if flag("gate") { cfg.gate = defaults.gate }
        if flag("comp") { cfg.comp = defaults.comp }
        if flag("exciter") { cfg.exciter = defaults.exciter }
        if flag("bassenh") { cfg.bassEnhancer = defaults.bassEnhancer }
        if let g = value("gain"), let v = Float(g) { cfg.gain = v }
        if value("hpf") == "75" { cfg.hpf = OC_HPF_75 }
        if value("hpf") == "150" { cfg.hpf = OC_HPF_150 }
        let (out, trace) = render(input, cfg)
        try WAV.write(out, to: args[2])
        printReport("in", analyse(input))
        printReport("out", analyse(out))
        printTrace(cfg, trace)

    case "measure":
        for path in args.dropFirst() where !path.hasPrefix("--") {
            printReport((path as NSString).lastPathComponent, analyse(try WAV.read(path)))
        }

    case "suite":
        guard args.count >= 3 else { usage() }
        let input = try WAV.read(args[1])
        let dir = args[2]
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var hpf = StripConfig(); hpf.hpf = OC_HPF_75
        var gate = StripConfig(); gate.gate = defaults.gate
        var comp = StripConfig(); comp.comp = defaults.comp
        var exc = StripConfig(); exc.exciter = defaults.exciter
        var big = StripConfig(); big.bassEnhancer = defaults.bassEnhancer
        var full = defaults; full.hpf = OC_HPF_75

        let stages: [(String, StripConfig)] = [
            ("00-dry", StripConfig()), ("01-hpf75", hpf), ("02-gate", gate),
            ("03-compressor", comp), ("04-exciter", exc), ("05-bassenhancer", big),
            ("06-full-chain", full),
        ]

        print("Reference (dry input):")
        printReport("input", analyse(input))
        print("\nStages:")
        for (name, cfg) in stages {
            let (out, trace) = render(input, cfg)
            try WAV.write(out, to: "\(dir)/\(name).wav")
            printReport(name, analyse(out))
            printTrace(cfg, trace)
        }
        print("\nWritten to \(dir). Listen to 00-dry.wav against the others.")

    case "thd":
        // Sweeps input level, because the whole question is whether these
        // stages behave the same on a quiet voice as on a loud one. A saturator
        // whose distortion collapses 30 dB below full scale is not a saturator
        // at normal speaking levels.
        let levels: [Double] = [-40, -30, -20, -12, -6, -3]
        for (name, hz, make) in [
            ("Exciter", 5000.0, { (a: Float) -> StripConfig in
                var c = StripConfig(); c.exciter = (amount: a, frequency: 3500, drive: 0.5); return c
            }),
            ("Bass Enhancer", 100.0, { (a: Float) -> StripConfig in
                var c = StripConfig(); c.bassEnhancer = (amount: a, frequency: 120, drive: 0.5); return c
            }),
        ] {
            print("\n\(name) — \(Int(hz)) Hz tone, default amount 0.35 vs maximum 1.0")
            print("   level     amount 0.35              amount 1.00")
            print("            THD%   2nd    3rd       THD%   2nd    3rd")
            for level in levels {
                let input = tone(hz: hz, dbfs: level, seconds: 2)
                var line = String(format: "  %5.0f dB", level)
                for amount in [Float(0.35), Float(1.0)] {
                    let h = harmonics(of: render(input, make(amount)).audio, fundamental: hz)
                    let h2 = h.harmonicDB.count > 0 ? h.harmonicDB[0] : -120
                    let h3 = h.harmonicDB.count > 1 ? h.harmonicDB[1] : -120
                    line += String(format: "   %6.3f %6.1f %6.1f", h.thdPercent, h2, h3)
                }
                print(line)
            }
        }

    default:
        usage()
    }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
