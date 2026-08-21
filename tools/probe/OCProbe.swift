import AudioToolbox
import CoreAudio
import Darwin

// Render a known tone into OpenConnect Sink and capture OpenConnect Mic.
// This exercises the driver's ring buffer end to end inside coreaudiod,
// with no application and no physical microphone involved.

let toneHz = 440.0
let seconds = 5.0
let amplitude: Float = 0.25

/// `--listen` measures whatever is already on OpenConnect Mic (i.e. the running
/// app's mix) instead of injecting a tone into the sink.
let listenOnly = CommandLine.arguments.contains("--listen")

func devices() -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz)
    var ids = [AudioObjectID](repeating: 0, count: Int(sz) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids)
    return ids
}

/// The sink is hidden, so it is absent from `kAudioHardwarePropertyDevices`.
/// Translation is the only way to reach it.
func deviceID(forUID uid: String) -> AudioObjectID {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cf = uid as CFString
    var dev = AudioObjectID(kAudioObjectUnknown)
    var sz = UInt32(MemoryLayout<AudioObjectID>.size)
    let st = withUnsafeMutablePointer(to: &cf) {
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a,
            UInt32(MemoryLayout<CFString>.size), $0, &sz, &dev)
    }
    return st == noErr ? dev : 0
}

let sink = deviceID(forUID: "OpenConnectSink_UID")
let mic = deviceID(forUID: "OpenConnectMic_UID")
guard sink != 0, mic != 0 else {
    fputs("sink=\(sink) mic=\(mic) — driver devices not found\n", stderr); exit(2)
}
print("sink id \(sink), mic id \(mic)")

func makeUnit(device: AudioObjectID, input: Bool) -> AudioUnit {
    var d = AudioComponentDescription(componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    let c = AudioComponentFindNext(nil, &d)!
    var u: AudioUnit? = nil
    AudioComponentInstanceNew(c, &u)
    var on: UInt32 = 1, off: UInt32 = 0
    if input {
        AudioUnitSetProperty(u!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4)
        AudioUnitSetProperty(u!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4)
    }
    var dev = device
    AudioUnitSetProperty(u!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, 4)
    var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    let scope: AudioUnitScope = input ? kAudioUnitScope_Output : kAudioUnitScope_Input
    let bus: AudioUnitElement = input ? 1 : 0
    AudioUnitSetProperty(u!, kAudioUnitProperty_StreamFormat, scope, bus, &asbd,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
    return u!
}

final class S { var phase = 0.0 }
let s = S()
let outUnit = makeUnit(device: sink, input: false)
var outCB = AURenderCallbackStruct(inputProc: { refCon, _, _, _, n, io -> OSStatus in
    let st = Unmanaged<S>.fromOpaque(refCon).takeUnretainedValue()
    guard let io else { return noErr }
    let bl = UnsafeMutableAudioBufferListPointer(io)
    let inc = 2.0 * Double.pi * toneHz / 48000.0
    for b in 0..<bl.count {
        let p = bl[b].mData!.assumingMemoryBound(to: Float.self)
        let ch = Int(bl[b].mNumberChannels)
        var ph = st.phase
        for i in 0..<Int(n) {
            let v = Float(sin(ph)) * amplitude
            for k in 0..<ch { p[i * ch + k] = v }
            ph += inc
        }
        if b == bl.count - 1 { st.phase = ph.truncatingRemainder(dividingBy: 2 * .pi) }
    }
    return noErr
}, inputProcRefCon: Unmanaged.passUnretained(s).toOpaque())
AudioUnitSetProperty(outUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
    &outCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

final class C {
    var au: AudioUnit! = nil
    var buf = UnsafeMutablePointer<Float>.allocate(capacity: 1 << 18)
    var list = AudioBufferList.allocate(maximumBuffers: 1)
    var sumSq = 0.0, frames = 0
    var peak: Float = 0
    var zeroRuns = 0
    var corrSin = 0.0, corrCos = 0.0
    var n = 0
}
let c = C()
let inUnit = makeUnit(device: mic, input: true)
c.au = inUnit
var inCB = AURenderCallbackStruct(inputProc: { refCon, flags, ts, bus, n, _ -> OSStatus in
    let c = Unmanaged<C>.fromOpaque(refCon).takeUnretainedValue()
    let f = Int(n)
    c.list[0].mNumberChannels = 2
    c.list[0].mDataByteSize = UInt32(f * 2 * 4)
    c.list[0].mData = UnsafeMutableRawPointer(c.buf)
    guard AudioUnitRender(c.au, flags, ts, bus, n, c.list.unsafeMutablePointer) == noErr else { return noErr }
    for i in 0..<f {
        let v = c.buf[i * 2]
        if v == 0 { c.zeroRuns += 1 }
        c.sumSq += Double(v) * Double(v)
        if abs(v) > c.peak { c.peak = abs(v) }
        let t = 2.0 * Double.pi * toneHz * Double(c.n) / 48000.0
        c.corrSin += Double(v) * sin(t)
        c.corrCos += Double(v) * cos(t)
        c.n += 1
    }
    c.frames += f
    return noErr
}, inputProcRefCon: Unmanaged.passUnretained(c).toOpaque())
AudioUnitSetProperty(inUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
    &inCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

for (u, label) in listenOnly ? [(inUnit, "mic")] : [(outUnit, "sink"), (inUnit, "mic")] {
    let i = AudioUnitInitialize(u)
    if i != noErr { fputs("\(label) init failed \(i)\n", stderr); exit(3) }
}
if !listenOnly {
    if AudioOutputUnitStart(outUnit) != noErr { fputs("sink start failed\n", stderr); exit(4) }
    usleep(300_000)
}
if AudioOutputUnitStart(inUnit) != noErr { fputs("mic start failed\n", stderr); exit(5) }
usleep(UInt32(seconds * 1_000_000))
AudioOutputUnitStop(inUnit); if !listenOnly { AudioOutputUnitStop(outUnit) }

func db(_ x: Double) -> String { x <= 0 ? "-inf" : String(format: "%.2f dBFS", 20 * log10(x)) }
print("frames captured: \(c.frames)  (expected ~\(Int(seconds * 48000)))")
if c.frames == 0 { print("NO CAPTURE"); exit(6) }
let rms = (c.sumSq / Double(c.frames)).squareRoot()
let mag = 2.0 * (c.corrSin * c.corrSin + c.corrCos * c.corrCos).squareRoot() / Double(c.n)
print("  rms      \(db(rms))    (tone alone would be \(db(Double(amplitude) / 2.0.squareRoot())))")
print("  peak     \(db(Double(c.peak)))   (sent amplitude \(db(Double(amplitude))))")
print("  440 Hz component \(db(mag))")
print("  exact-zero samples: \(c.zeroRuns) of \(c.frames) (\(String(format: "%.2f", 100.0 * Double(c.zeroRuns) / Double(c.frames)))%)")
let ratio = mag / Double(amplitude)
print(String(format: "  tone recovered at %.1f%% of sent amplitude", ratio * 100))
