import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Fixed limits
//
// Everything the render path can ever need is allocated once, at these sizes,
// before the engine starts. Nothing below this line allocates.

let kMaxChannels = 8
/// Largest block we will ever be asked for in one callback. We additionally
/// chunk work to `OC_MAX_BLOCK` inside the callback.
let kMaxFrames = 4096
let kDSPChunk = 1024
/// Input ring capacity in frames. Must be a power of two.
let kRingCapacity: UInt32 = 32768
/// Steady-state ring occupancy the drift controller aims for, in frames. Large
/// enough to absorb USB scheduling jitter, small enough to keep latency low.
let kRingTargetFill: Float = 1536
/// Meter fall-back time. Matches the decay already used by the channel strip's
/// own meters so a bar does not drop at a different speed depending on which
/// point in the signal it is watching.
let kMeterDecayMS: Float = 300

/// Applies the drift controller tuning.
///
/// This is the single definition of the PI tuning. It is applied both when a
/// channel is first allocated and again whenever a channel is rebound to a new
/// device, so it must not be duplicated at the call sites — retuning one copy
/// and not the other would make behaviour depend on whether a rebind had
/// happened.
///
/// The correction must stay in the parts-per-million range so it can never be
/// heard, and the integrator, the ratio and the slew rate are all clamped so
/// that no transient can produce an audible step.
///
/// The gains are chosen for *damping*, not just for gentleness. The fill level
/// is the integral of the rate error, so the loop is second order:
///
///     with a = blockSize*kp and b = blockSize*ki,
///     natural frequency  = sqrt(b) rad/update,
///     damping ratio      = a / (2*sqrt(b)),
///     2% settling        ~ 8/a updates.
///
/// The original tuning (kp 2.0e-7, ki 4.0e-9) gave a damping ratio of 0.036,
/// which is essentially undamped. It held a steady crystal offset perfectly
/// well, but a one-block step disturbance rang for six minutes and overshot
/// far enough to come within a whisker of an underrun. That was measured both
/// in `testControllerAbsorbsAOneBlockStepWithoutRinging` and on real hardware.
///
/// These values give a damping ratio near 0.9 and settle a 512-frame step in
/// well under a minute, while the correction stays inside a millionth-scale
/// band that is inaudible throughout.
func ocConfigureDriftController(_ drift: UnsafeMutablePointer<oc_drift_controller>) {
    oc_drift_controller_init(
        drift,
        kRingTargetFill,
        /* kp */ 2.8e-6,
        /* ki */ 1.2e-9,
        /* integrator_limit */ 5.0e-4,
        /* ratio_limit */ 1.0e-3,
        /* slew_per_update */ 5.0e-6)
}

// MARK: - Parameter mirror
//
// The render thread cannot read Swift objects, so every parameter it needs is
// mirrored into this plain C-layout struct. Effect setters take all of their
// parameters at once, so we keep the current value of each and reconfigure the
// affected effect whenever one of them changes.

struct ChannelParams {
    var gainDB: Float = 0
    var padDB: Float = -20
    var padEnabled: Float = 0

    var hpfMode: Int32 = 0
    var hpfFrequency: Float = 100

    var gateEnabled: Float = 0
    var gateThresholdDB: Float = -45
    var gateAttackMS: Float = 2
    var gateHoldMS: Float = 80
    var gateReleaseMS: Float = 150
    var gateHysteresisDB: Float = 6
    var gateRangeDB: Float = -60

    var compEnabled: Float = 0
    var compThresholdDB: Float = -18
    var compRatio: Float = 3
    var compAttackMS: Float = 10
    var compReleaseMS: Float = 120
    var compMakeupDB: Float = 0
    var compKneeDB: Float = 6

    var exciterEnabled: Float = 0
    var exciterAmount: Float = 0.35
    var exciterFrequency: Float = 3500
    var exciterDrive: Float = 0.5

    var bottomEnabled: Float = 0
    var bottomAmount: Float = 0.35
    var bottomFrequency: Float = 120
    var bottomDrive: Float = 0.5

    var faderDB: Float = 0
    var muted: Float = 0
}

// MARK: - Per-channel realtime state

struct ChannelRT {
    var strip: UnsafeMutablePointer<oc_channel_strip>! = nil
    var ring: UnsafeMutablePointer<oc_ring_buffer>! = nil
    var ringStorage: UnsafeMutablePointer<Float>! = nil
    var resampler: UnsafeMutablePointer<oc_resampler>! = nil
    var drift: UnsafeMutablePointer<oc_drift_controller>! = nil

    /// Resampled, pre-DSP mono input for this block.
    var pulled: UnsafeMutablePointer<Float>! = nil
    /// Post-DSP mono signal for this block.
    var processed: UnsafeMutablePointer<Float>! = nil

    var params = ChannelParams()

    /// Linear fader gain, ramped per block so moves are never audible as steps.
    var faderGain: Float = 1
    var targetGain: Float = 1

    /// Level of this channel's *actual contribution to the mix* — measured after
    /// the fader and after mute, not before them.
    ///
    /// The strip's own output meter sits inside `oc_channel_strip`, which knows
    /// nothing about the fader or the mute button, both of which live out here
    /// in the mixer. Metering there meant a muted or fully closed channel still
    /// showed a bouncing bar, and pulling a fader down moved nothing at all.
    /// A meter that does not answer "what am I sending?" is worse than no meter,
    /// because it is confidently wrong.
    var postFaderMeter: UnsafeMutablePointer<oc_meter>! = nil

    /// Set by the input side once the device is delivering audio.
    var active: Int32 = 0
    /// Native sample rate of the hardware device feeding this channel.
    var nativeSampleRate: Double = 48_000

    var underruns: UInt32 = 0
    var overruns: UInt32 = 0

    /// Host time of the previous input callback, and the largest gap between
    /// two consecutive input callbacks since the diagnostics were last read.
    ///
    /// These exist to answer one specific question that the fill level alone
    /// cannot: when the ring level steps down, did the *input* stall, or did the
    /// output run extra cycles? A gap materially longer than the device period
    /// means the microphone's callback was late, which is a scheduling problem
    /// outside this process and nothing the drift controller can prevent.
    /// Reading the timebase is a register read on Apple silicon, so this is
    /// render-safe.
    var lastInputHostTime: UInt64 = 0
    var maxInputGapUS: UInt32 = 0
    /// Frames delivered by the largest single input callback, which separates
    /// "callback was late" from "callback was late and then delivered the
    /// backlog in one go".
    var maxInputFrames: UInt32 = 0
    /// Published for diagnostics: deviation from nominal, in parts per million.
    var ratioPPM: Double = 0
    var fillFrames: Double = 0
}

// MARK: - Engine-wide realtime state

struct EngineRT {
    var channels: UnsafeMutablePointer<ChannelRT>! = nil
    var channelCount: Int32 = 0

    var paramQueue: UnsafeMutablePointer<oc_param_queue>! = nil
    var paramStorage: UnsafeMutablePointer<oc_param_event>! = nil

    var mix: UnsafeMutablePointer<Float>! = nil

    /// Level of the summed mix — what the virtual device actually publishes, and
    /// therefore the only number that answers "am I too quiet or too loud for
    /// the other end of the call?". Every per-channel meter is a component of
    /// this; none of them is a substitute for it.
    var masterMeter: UnsafeMutablePointer<oc_meter>! = nil

    var sampleRate: Double = 48_000
}

// MARK: - Allocation / teardown
//
// Called from the main thread only, while the engine is stopped.

enum RTAlloc {
    static func makeEngine(sampleRate: Double) -> UnsafeMutablePointer<EngineRT> {
        let engine = UnsafeMutablePointer<EngineRT>.allocate(capacity: 1)
        engine.initialize(to: EngineRT())
        engine.pointee.sampleRate = sampleRate

        let channels = UnsafeMutablePointer<ChannelRT>.allocate(capacity: kMaxChannels)
        for i in 0..<kMaxChannels {
            (channels + i).initialize(to: makeChannel(sampleRate: sampleRate))
        }
        engine.pointee.channels = channels
        engine.pointee.channelCount = 0

        let queue = UnsafeMutablePointer<oc_param_queue>.allocate(capacity: 1)
        let queueStorage = UnsafeMutablePointer<oc_param_event>.allocate(capacity: 1024)
        queueStorage.initialize(repeating: oc_param_event(param_id: 0, value: 0), count: 1024)
        _ = oc_param_queue_init(queue, queueStorage, 1024)
        engine.pointee.paramQueue = queue
        engine.pointee.paramStorage = queueStorage

        let mix = UnsafeMutablePointer<Float>.allocate(capacity: kMaxFrames)
        mix.initialize(repeating: 0, count: kMaxFrames)
        engine.pointee.mix = mix

        let master = UnsafeMutablePointer<oc_meter>.allocate(capacity: 1)
        oc_meter_init(master, sampleRate, kMeterDecayMS)
        engine.pointee.masterMeter = master

        return engine
    }

    private static func makeChannel(sampleRate: Double) -> ChannelRT {
        var channel = ChannelRT()

        let strip = UnsafeMutablePointer<oc_channel_strip>.allocate(capacity: 1)
        oc_channel_strip_init(strip, sampleRate)
        channel.strip = strip

        let storage = UnsafeMutablePointer<Float>.allocate(capacity: Int(kRingCapacity))
        storage.initialize(repeating: 0, count: Int(kRingCapacity))
        let ring = UnsafeMutablePointer<oc_ring_buffer>.allocate(capacity: 1)
        _ = oc_ring_buffer_init(ring, storage, kRingCapacity)
        channel.ring = ring
        channel.ringStorage = storage

        let resampler = UnsafeMutablePointer<oc_resampler>.allocate(capacity: 1)
        oc_resampler_init(resampler, 1.0)
        channel.resampler = resampler

        let drift = UnsafeMutablePointer<oc_drift_controller>.allocate(capacity: 1)
        ocConfigureDriftController(drift)
        channel.drift = drift

        let pulled = UnsafeMutablePointer<Float>.allocate(capacity: kMaxFrames)
        pulled.initialize(repeating: 0, count: kMaxFrames)
        channel.pulled = pulled

        let processed = UnsafeMutablePointer<Float>.allocate(capacity: kMaxFrames)
        processed.initialize(repeating: 0, count: kMaxFrames)
        channel.processed = processed

        let postFader = UnsafeMutablePointer<oc_meter>.allocate(capacity: 1)
        oc_meter_init(postFader, sampleRate, kMeterDecayMS)
        channel.postFaderMeter = postFader

        return channel
    }

    static func destroy(_ engine: UnsafeMutablePointer<EngineRT>) {
        let channels = engine.pointee.channels!
        for i in 0..<kMaxChannels {
            let channel = (channels + i).pointee
            channel.strip.deallocate()
            channel.ring.deallocate()
            channel.ringStorage.deallocate()
            channel.resampler.deallocate()
            channel.drift.deallocate()
            channel.pulled.deallocate()
            channel.processed.deallocate()
            channel.postFaderMeter.deallocate()
        }
        channels.deinitialize(count: kMaxChannels)
        channels.deallocate()

        engine.pointee.paramQueue.deallocate()
        engine.pointee.paramStorage.deallocate()
        engine.pointee.mix.deallocate()
        engine.pointee.masterMeter.deallocate()

        engine.deinitialize(count: 1)
        engine.deallocate()
    }
}

// MARK: - Parameter application (render thread)

/// Applies one queued parameter change. Every branch is a plain arithmetic
/// store or a call into the dependency-free DSP core; nothing here allocates,
/// locks, logs or touches the Swift runtime.
@inline(__always)
func rtApplyParam(_ channel: UnsafeMutablePointer<ChannelRT>, _ paramID: UInt32, _ value: Float) {
    let selector = paramID & 0xFFFF
    let p = channel.pointee.strip!

    switch selector {
    case OCParam.gainDB.rawValue:
        channel.pointee.params.gainDB = value
        oc_channel_strip_set_gain_db(p, value)

    case OCParam.padDB.rawValue, OCParam.padEnabled.rawValue:
        if selector == OCParam.padDB.rawValue {
            channel.pointee.params.padDB = value
        } else {
            channel.pointee.params.padEnabled = value
        }
        let pad = channel.pointee.params.padEnabled > 0.5 ? channel.pointee.params.padDB : 0
        oc_channel_strip_set_pad_db(p, pad)

    case OCParam.hpfMode.rawValue, OCParam.hpfFrequency.rawValue:
        if selector == OCParam.hpfMode.rawValue {
            channel.pointee.params.hpfMode = Int32(value)
        } else {
            channel.pointee.params.hpfFrequency = value
        }
        oc_channel_strip_set_hpf(
            p,
            oc_hpf_mode(UInt32(max(0, min(3, channel.pointee.params.hpfMode)))),
            channel.pointee.params.hpfFrequency)

    case OCParam.gateThresholdDB.rawValue...OCParam.gateRangeDB.rawValue:
        switch selector {
        case OCParam.gateThresholdDB.rawValue: channel.pointee.params.gateThresholdDB = value
        case OCParam.gateAttackMS.rawValue: channel.pointee.params.gateAttackMS = value
        case OCParam.gateHoldMS.rawValue: channel.pointee.params.gateHoldMS = value
        case OCParam.gateReleaseMS.rawValue: channel.pointee.params.gateReleaseMS = value
        case OCParam.gateHysteresisDB.rawValue: channel.pointee.params.gateHysteresisDB = value
        default: channel.pointee.params.gateRangeDB = value
        }
        let g = channel.pointee.params
        oc_gate_configure(
            &p.pointee.gate,
            g.gateThresholdDB, g.gateAttackMS, g.gateHoldMS, g.gateReleaseMS, g.gateHysteresisDB,
            g.gateRangeDB)

    case OCParam.compThresholdDB.rawValue...OCParam.compKneeDB.rawValue:
        switch selector {
        case OCParam.compThresholdDB.rawValue: channel.pointee.params.compThresholdDB = value
        case OCParam.compRatio.rawValue: channel.pointee.params.compRatio = value
        case OCParam.compAttackMS.rawValue: channel.pointee.params.compAttackMS = value
        case OCParam.compReleaseMS.rawValue: channel.pointee.params.compReleaseMS = value
        case OCParam.compMakeupDB.rawValue: channel.pointee.params.compMakeupDB = value
        default: channel.pointee.params.compKneeDB = value
        }
        let c = channel.pointee.params
        oc_compressor_configure(
            &p.pointee.compressor,
            c.compThresholdDB, c.compRatio, c.compAttackMS, c.compReleaseMS,
            c.compMakeupDB, c.compKneeDB, OC_DETECTOR_RMS)

    case OCParam.exciterAmount.rawValue...OCParam.exciterDrive.rawValue:
        switch selector {
        case OCParam.exciterAmount.rawValue: channel.pointee.params.exciterAmount = value
        case OCParam.exciterFrequency.rawValue: channel.pointee.params.exciterFrequency = value
        default: channel.pointee.params.exciterDrive = value
        }
        let e = channel.pointee.params
        oc_exciter_configure(&p.pointee.exciter, e.exciterAmount, e.exciterFrequency, e.exciterDrive)

    case OCParam.bassEnhancerAmount.rawValue...OCParam.bassEnhancerDrive.rawValue:
        switch selector {
        case OCParam.bassEnhancerAmount.rawValue: channel.pointee.params.bottomAmount = value
        case OCParam.bassEnhancerFrequency.rawValue: channel.pointee.params.bottomFrequency = value
        default: channel.pointee.params.bottomDrive = value
        }
        let b = channel.pointee.params
        oc_bass_enhancer_configure(&p.pointee.bass_enhancer, b.bottomAmount, b.bottomFrequency, b.bottomDrive)

    case OCParam.gateEnabled.rawValue, OCParam.compressorEnabled.rawValue,
         OCParam.exciterEnabled.rawValue, OCParam.bassEnhancerEnabled.rawValue:
        switch selector {
        case OCParam.gateEnabled.rawValue: channel.pointee.params.gateEnabled = value
        case OCParam.compressorEnabled.rawValue: channel.pointee.params.compEnabled = value
        case OCParam.exciterEnabled.rawValue: channel.pointee.params.exciterEnabled = value
        default: channel.pointee.params.bottomEnabled = value
        }
        let s = channel.pointee.params
        // The strip takes *bypass* flags, so these are inverted.
        oc_channel_strip_set_bypasses(
            p,
            s.gateEnabled > 0.5 ? 0 : 1,
            s.compEnabled > 0.5 ? 0 : 1,
            s.exciterEnabled > 0.5 ? 0 : 1,
            s.bottomEnabled > 0.5 ? 0 : 1)

    case OCParam.faderDB.rawValue:
        channel.pointee.params.faderDB = value
        rtRecomputeTargetGain(channel)

    case OCParam.muted.rawValue, OCParam.effectivelyMuted.rawValue:
        channel.pointee.params.muted = value
        rtRecomputeTargetGain(channel)

    default:
        break
    }
}

@inline(__always)
func rtRecomputeTargetGain(_ channel: UnsafeMutablePointer<ChannelRT>) {
    if channel.pointee.params.muted > 0.5 {
        channel.pointee.targetGain = 0
    } else {
        channel.pointee.targetGain = oc_db_to_linear(channel.pointee.params.faderDB)
    }
}

// MARK: - Output render callback (the master clock)

/// Everything downstream of here is driven by this callback: it is the single
/// clock the whole app runs on. Each input device has its own, slightly
/// different clock, and the drift controller below is what reconciles them.
let ocOutputRenderCallback: AURenderCallback = {
    inRefCon, _, _, _, inNumberFrames, ioData -> OSStatus in

    let engine = inRefCon.assumingMemoryBound(to: EngineRT.self)
    guard let ioData else { return noErr }

    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    let frames = Int(inNumberFrames)
    guard frames > 0, frames <= kMaxFrames, buffers.count > 0 else { return noErr }

    // 1. Drain pending parameter changes.
    var event = oc_param_event(param_id: 0, value: 0)
    let queue = engine.pointee.paramQueue!
    while oc_param_queue_pop(queue, &event) != 0 {
        let index = Int(event.param_id >> 16)
        if index >= 0 && index < kMaxChannels {
            rtApplyParam(engine.pointee.channels + index, event.param_id, event.value)
        }
    }

    // 2. Start from silence, then sum every active channel in.
    let mix = engine.pointee.mix!
    memset(mix, 0, frames * MemoryLayout<Float>.size)

    let channelCount = Int(engine.pointee.channelCount)
    let outputRate = engine.pointee.sampleRate

    for index in 0..<min(channelCount, kMaxChannels) {
        let channel = engine.pointee.channels + index
        guard channel.pointee.active != 0 else {
            // An inactive channel contributes nothing, so its meter must read
            // nothing. Without this it would freeze at whatever it showed when
            // the microphone was unplugged and stay there.
            oc_meter_reset(channel.pointee.postFaderMeter)
            continue
        }

        // 2a. Drift control. The ring fill level is the error signal: if the
        // microphone's clock is fractionally faster than ours the ring slowly
        // fills, and we consume fractionally faster to compensate. The
        // correction is applied on top of the nominal rate ratio.
        let fill = Float(oc_ring_buffer_fill_level(channel.pointee.ring))
        let correction = oc_drift_controller_update(channel.pointee.drift, fill)
        let nominal = channel.pointee.nativeSampleRate / outputRate
        oc_resampler_set_ratio(channel.pointee.resampler, nominal * Double(correction))

        channel.pointee.fillFrames = Double(fill)
        channel.pointee.ratioPPM = (Double(correction) - 1.0) * 1.0e6

        // 2b. Pull exactly the frames we owe, resampled onto our clock.
        let produced = oc_resampler_pull(
            channel.pointee.resampler, channel.pointee.ring, channel.pointee.pulled, UInt32(frames))
        if produced < UInt32(frames) {
            channel.pointee.underruns &+= 1

            // Zero the tail the resampler could not fill, so a short pull leaves
            // silence rather than the previous block's stale samples.
            let start = Int(produced)
            memset(channel.pointee.pulled + start, 0,
                   (frames - start) * MemoryLayout<Float>.size)

            // A genuinely empty ring means the device stalled or was pulled.
            // Re-prime rather than limp along underrunning every block: drop
            // back to inactive so the input side rebuilds the cushion, and
            // reset the controller so a wound-up integrator is not carried
            // into the new run.
            if oc_ring_buffer_fill_level(channel.pointee.ring) == 0 {
                channel.pointee.active = 0
                ocConfigureDriftController(channel.pointee.drift)
                oc_resampler_init(channel.pointee.resampler,
                                  channel.pointee.nativeSampleRate / outputRate)
            }
        }

        // 2c. Muted, and the fader has already finished its ramp down to zero.
        // Everything from here to the sum would be multiplied by exactly zero,
        // so it is skipped -- but only after 2a and 2b, which must keep running:
        // the device is still filling this ring whether or not anyone is
        // listening to it, and a channel that stops draining its ring hands you
        // a backlog instead of the present when it comes back.
        //
        // The ramp is what makes the test safe. targetGain reaches zero the
        // moment mute is pressed, but faderGain only catches up at the end of
        // that block, so the fast path starts one block later and the mute
        // itself is still a ramp rather than a cut. Unmuting is symmetrical:
        // faderGain is zero, so the first audible block ramps up from silence.
        if channel.pointee.targetGain == 0 && channel.pointee.faderGain == 0 {
            oc_channel_strip_process_muted(
                channel.pointee.strip, channel.pointee.pulled, UInt32(frames))
            oc_meter_process_silence(channel.pointee.postFaderMeter, UInt32(frames))
            continue
        }

        // 2d. Full DSP chain, in bounded chunks.
        var offset = 0
        while offset < frames {
            let n = min(kDSPChunk, frames - offset)
            oc_channel_strip_process(
                channel.pointee.strip,
                channel.pointee.pulled + offset,
                channel.pointee.processed + offset,
                UInt32(n))
            offset += n
        }

        // 2e. Fader, ramped across the block so moves never step, applied in
        // place so the result can be metered before it is summed. This is the
        // only point at which the signal is exactly what this channel sends to
        // the mix — after gain, after the DSP chain, after the fader, and after
        // mute (which is just a fader target of zero).
        let start = channel.pointee.faderGain
        let end = channel.pointee.targetGain
        let step = (end - start) / Float(frames)
        var gain = start
        let src = channel.pointee.processed!
        for i in 0..<frames {
            src[i] *= gain
            gain += step
        }
        channel.pointee.faderGain = end

        oc_meter_process_block(channel.pointee.postFaderMeter, src, UInt32(frames))

        for i in 0..<frames {
            mix[i] += src[i]
        }
    }

    // 2f. Meter the sum. Done before publishing so the number the user reads is
    // the number the virtual device hands to Teams or Zoom, not an estimate.
    oc_meter_process_block(engine.pointee.masterMeter, mix, UInt32(frames))

    // 3. Publish the mix. The virtual device is stereo (kChannelCount == 2 in
    // the driver) because that is what conferencing apps expect, but both mics
    // are mono sources, so the same summed signal is written to every output
    // channel: a centre image on a stereo device, not a mono device.
    for bufferIndex in 0..<buffers.count {
        guard let data = buffers[bufferIndex].mData else { continue }
        let out = data.assumingMemoryBound(to: Float.self)
        let channelsInBuffer = Int(buffers[bufferIndex].mNumberChannels)
        if channelsInBuffer == 1 {
            memcpy(out, mix, frames * MemoryLayout<Float>.size)
        } else {
            // Interleaved fallback.
            for i in 0..<frames {
                let sample = mix[i]
                for c in 0..<channelsInBuffer {
                    out[i * channelsInBuffer + c] = sample
                }
            }
        }
    }

    return noErr
}

// MARK: - Input capture

/// Per-input-device realtime state. One of these exists per hardware mic.
struct InputRT {
    var unit: AudioUnit? = nil
    var channel: UnsafeMutablePointer<ChannelRT>! = nil
    var bufferList: UnsafeMutablePointer<AudioBufferList>! = nil
    var interleaved: UnsafeMutablePointer<Float>! = nil
    var mono: UnsafeMutablePointer<Float>! = nil
    var hardwareChannels: Int32 = 1
}

/// Converts mach host ticks to microseconds using a timebase cached at load.
///
/// `mach_timebase_info` allocates nothing but is a call into the kernel's
/// commpage; caching it in a `let` means the render path only ever multiplies.
private let ocHostTimebase: (numer: Double, denom: Double) = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return (Double(info.numer), Double(info.denom))
}()

@inline(__always)
func ocHostTicksToMicroseconds(_ ticks: UInt64) -> UInt32 {
    let ns = Double(ticks) * ocHostTimebase.numer / ocHostTimebase.denom
    let us = ns / 1000.0
    return us >= 4_000_000 ? 4_000_000 : UInt32(us)
}

/// Input callback: pull the hardware's frames and hand them to the ring buffer.
///
/// This runs on the *device's* clock, which is not the output clock — that
/// mismatch is the entire reason the ring buffer and drift controller exist.
let ocInputRenderCallback: AURenderCallback = {
    inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ -> OSStatus in

    let input = inRefCon.assumingMemoryBound(to: InputRT.self)
    guard let unit = input.pointee.unit else { return noErr }
    let frames = Int(inNumberFrames)
    guard frames > 0, frames <= kMaxFrames else { return noErr }

    let list = input.pointee.bufferList!
    let hardwareChannels = Int(input.pointee.hardwareChannels)

    // Re-arm the preallocated buffer list; AudioUnitRender mutates it.
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    buffers.count = 1
    buffers[0].mNumberChannels = UInt32(hardwareChannels)
    buffers[0].mDataByteSize = UInt32(frames * hardwareChannels * MemoryLayout<Float>.size)
    buffers[0].mData = UnsafeMutableRawPointer(input.pointee.interleaved)

    let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, list)
    guard status == noErr else { return noErr }

    // Downmix to mono. Most USB microphones that present two channels carry the
    // same signal on both, so averaging preserves level rather than halving it.
    let interleaved = input.pointee.interleaved!
    let mono = input.pointee.mono!
    if hardwareChannels == 1 {
        memcpy(mono, interleaved, frames * MemoryLayout<Float>.size)
    } else {
        let scale = 1.0 / Float(hardwareChannels)
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<hardwareChannels {
                sum += interleaved[i * hardwareChannels + c]
            }
            mono[i] = sum * scale
        }
    }

    // Timing, before the write, so a slow write cannot be mistaken for a gap.
    let now = mach_absolute_time()
    let channel = input.pointee.channel!
    if channel.pointee.lastInputHostTime != 0 {
        let deltaUS = ocHostTicksToMicroseconds(now &- channel.pointee.lastInputHostTime)
        if deltaUS > channel.pointee.maxInputGapUS { channel.pointee.maxInputGapUS = deltaUS }
    }
    channel.pointee.lastInputHostTime = now
    if UInt32(frames) > channel.pointee.maxInputFrames {
        channel.pointee.maxInputFrames = UInt32(frames)
    }

    let written = oc_ring_buffer_write(input.pointee.channel.pointee.ring, mono, UInt32(frames))
    if written < UInt32(frames) {
        // The consumer is behind. Count it; the drift controller will pull the
        // fill level back down over the next few seconds.
        input.pointee.channel.pointee.overruns &+= 1
    }

    // Priming. The output side must not start draining this ring until it holds
    // a full cushion.
    //
    // Marking the channel active on the first input block — which is what this
    // used to do — leaves the ring holding exactly one hardware period. The
    // resampler needs slightly *more* input than output for its interpolation
    // window, so every single pull came up short: on real hardware this produced
    // ~190 underruns per second per channel, forever, and drove the drift
    // controller's integrator to its limit chasing a fill level it had no way to
    // reach. The controller can only bend the consumption rate by parts per
    // million; it cannot conjure the initial cushion. Priming is the only fix.
    if input.pointee.channel.pointee.active == 0 {
        if oc_ring_buffer_fill_level(input.pointee.channel.pointee.ring) >= UInt32(kRingTargetFill) {
            input.pointee.channel.pointee.active = 1
        }
    }

    return noErr
}
