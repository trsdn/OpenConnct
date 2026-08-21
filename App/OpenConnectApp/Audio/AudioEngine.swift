import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Owns the audio graph: one AUHAL input unit per microphone, plus one AUHAL
/// output unit rendering into the hidden "OpenConnect Sink" device published by
/// our HAL plug-in.
///
/// Threading contract: every method here is called from the main thread. The
/// render callbacks in `AudioEngineRT.swift` touch only preallocated C-layout
/// memory and never call into this class.
final class AudioEngine {
    /// Fired when the set of connected input devices changes.
    var onDevicesChanged: (([AudioInputDevice]) -> Void)?
    /// Fired when the set of *selectable* input devices changes — that is, every
    /// physical input the machine has, whether or not the user enabled it.
    var onAvailableDevicesChanged: (([AudioInputDevice]) -> Void)?
    /// Fired when the virtual sink appears or disappears.
    var onSinkAvailabilityChanged: ((Bool) -> Void)?

    private let deviceManager = AudioDeviceManager()
    private let selectionStore = DeviceSelectionStore()
    private let rt: UnsafeMutablePointer<EngineRT>

    private var outputUnit: AudioUnit?
    private var inputs: [UnsafeMutablePointer<InputRT>] = []
    private var boundDevices: [AudioInputDevice] = []
    /// Running dropout total as of the last diagnostics poll, and when it last
    /// grew. Used to report *recent* dropouts rather than lifetime ones.
    private var lastDropoutTotal: UInt64 = 0
    private var lastDropoutAt: Date?
    /// Every physical input currently attached, before the user's selection is
    /// applied. Kept so the selection UI can offer devices we are not using.
    private(set) var availableDevices: [AudioInputDevice] = []
    /// `nil` means "the user has never chosen", which we treat as "use everything".
    private var enabledUIDs: Set<String>?

    private var running = false
    private var sinkAvailable = false

    private let sampleRate: Double = 48_000

    init() {
        rt = RTAlloc.makeEngine(sampleRate: 48_000)
        enabledUIDs = selectionStore.load()
    }

    deinit {
        stop()
        RTAlloc.destroy(rt)
    }

    // MARK: - Device selection

    /// The UIDs the user has enabled, or `nil` before they have ever chosen.
    var enabledDeviceUIDs: Set<String>? { enabledUIDs }

    /// Replaces the selection and rebinds. Passing an empty set is legitimate —
    /// it means the user wants no inputs — and is persisted as such.
    func setEnabledDeviceUIDs(_ uids: Set<String>) {
        enabledUIDs = uids
        selectionStore.save(uids)
        rebind(devices: availableDevices)
    }

    /// Applies the user's selection to a raw device list.
    ///
    /// Before the user has chosen anything, the default is every input *except*
    /// the built-in microphone. Plugging a microphone in is a statement of
    /// intent, and quietly mixing the machine's own microphone in alongside it
    /// adds keyboard and fan noise to the outgoing feed — the sort of fault
    /// nobody notices until someone on the other end of a call mentions it.
    /// If the built-in is the only input there is, it is used, because an app
    /// with no inputs at all would be worse.
    ///
    /// This deliberately lives here rather than in the UI: it is a default, not
    /// a choice, so it must not be written to disk as though the user had made
    /// it. Ticking the box in Input Devices is what makes a selection explicit.
    private func selected(from devices: [AudioInputDevice]) -> [AudioInputDevice] {
        guard let enabledUIDs else {
            let external = devices.filter { !$0.isBuiltIn }
            return external.isEmpty ? devices : external
        }
        return devices.filter { enabledUIDs.contains($0.uid) }
    }

    // MARK: - Lifecycle

    func start() {
        deviceManager.onChange = { [weak self] devices in
            self?.rebind(devices: devices)
        }
        deviceManager.startObserving()
        rebind(devices: deviceManager.currentInputDevices())
    }

    func stop() {
        deviceManager.stopObserving()
        teardownInputs()
        teardownOutput()
        running = false
    }

    /// Requests microphone access, then starts. Completion reports whether the
    /// user granted it.
    func requestPermissionAndStart(_ completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        NSLog("OpenConnect: microphone authorizationStatus = %d (%@), bundle = %@",
              status.rawValue, Self.describe(status), Bundle.main.bundlePath)
        switch status {
        case .authorized:
            start()
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                NSLog("OpenConnect: requestAccess returned granted = %@", granted ? "true" : "false")
                DispatchQueue.main.async {
                    if granted { self.start() }
                    completion(granted)
                }
            }
        default:
            completion(false)
        }
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Device binding

    /// Rebuilds the graph for the current device set.
    ///
    /// The output unit and the virtual device are deliberately never torn down
    /// here, so a microphone appearing or disappearing cannot interrupt the
    /// stream that Zoom or Teams is holding open.
    private func rebind(devices: [AudioInputDevice]) {
        if devices != availableDevices {
            availableDevices = devices
            onAvailableDevicesChanged?(devices)
        }
        let usable = Array(selected(from: devices).prefix(kMaxChannels))

        if usable != boundDevices {
            // Silence the render callback before mutating the state it reads.
            // Stopping (not disposing) the output unit keeps the virtual device
            // alive, so a client like Zoom sees a brief gap rather than a
            // disconnect — and we get a race-free window to rebuild channels.
            if let unit = outputUnit {
                AudioOutputUnitStop(unit)
            }
            teardownInputs()
            rt.pointee.channelCount = 0

            boundDevices = usable

            for (index, device) in usable.enumerated() {
                let channel = rt.pointee.channels + index
                channel.pointee.active = 0
                channel.pointee.nativeSampleRate = device.nominalSampleRate
                channel.pointee.underruns = 0
                channel.pointee.overruns = 0
                oc_channel_strip_init(channel.pointee.strip, sampleRate)
                oc_resampler_init(channel.pointee.resampler, device.nominalSampleRate / sampleRate)
                ocConfigureDriftController(channel.pointee.drift)
                if let input = makeInputUnit(for: device, channel: channel) {
                    inputs.append(input)
                }
            }

            // Only now is it safe for the render callback to see these channels.
            rt.pointee.channelCount = Int32(usable.count)
            // The per-channel counters were just zeroed, so the running total the
            // dropout-recency check compares against has to be zeroed with them,
            // or the next poll sees a large negative delta.
            lastDropoutTotal = 0
            onDevicesChanged?(usable)
        }

        NSLog("OpenConnect: %d input(s) available, %d bound: %@",
              availableDevices.count, usable.count,
              usable.map(\.name).joined(separator: ", "))
        ensureOutputRunning()
        NSLog("OpenConnect: sinkAvailable = %@, outputUnit = %@, inputUnits = %d",
              sinkAvailable ? "true" : "false",
              outputUnit == nil ? "nil" : "ok", inputs.count)
        for input in inputs {
            if let unit = input.pointee.unit {
                AudioOutputUnitStart(unit)
            }
        }
        running = true
    }

    private func ensureOutputRunning() {
        let available = deviceManager.sinkDeviceID() != nil
        if available != sinkAvailable {
            sinkAvailable = available
            onSinkAvailabilityChanged?(available)
        }
        guard available else {
            // The driver is not installed (or coreaudiod has not picked it up
            // yet). Inputs still run, so meters work and the user can configure
            // everything; there is simply nowhere to send the mix.
            teardownOutput()
            return
        }
        if outputUnit == nil {
            outputUnit = makeOutputUnit()
        }
        if let unit = outputUnit {
            AudioOutputUnitStart(unit)
        }
    }

    // MARK: - Output unit

    private func makeOutputUnit() -> AudioUnit? {
        guard let sink = deviceManager.sinkDeviceID() else { return nil }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }

        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else { return nil }

        var deviceID = sink
        guard AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            AudioComponentInstanceDispose(unit)
            return nil
        }

        var format = Self.nonInterleavedFormat(sampleRate: sampleRate, channels: 2)
        guard AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
            &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else {
            AudioComponentInstanceDispose(unit)
            return nil
        }

        var callback = AURenderCallbackStruct(
            inputProc: ocOutputRenderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(rt))
        guard AudioUnitSetProperty(
            unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
            AudioUnitInitialize(unit) == noErr else {
            AudioComponentInstanceDispose(unit)
            return nil
        }
        return unit
    }

    private func teardownOutput() {
        guard let unit = outputUnit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        outputUnit = nil
    }

    // MARK: - Input units

    private func makeInputUnit(
        for device: AudioInputDevice,
        channel: UnsafeMutablePointer<ChannelRT>
    ) -> UnsafeMutablePointer<InputRT>? {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }

        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else { return nil }

        var enable: UInt32 = 1
        var disable: UInt32 = 0
        // Bus 1 is input from hardware, bus 0 is output to hardware. We want the
        // former only.
        guard AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                &enable, UInt32(MemoryLayout<UInt32>.size)) == noErr,
              AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                &disable, UInt32(MemoryLayout<UInt32>.size)) == noErr else {
            AudioComponentInstanceDispose(unit)
            return nil
        }

        var deviceID = device.objectID
        guard AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            AudioComponentInstanceDispose(unit)
            return nil
        }

        // Ask for the device's native rate. We do our own rate conversion, and
        // letting AUHAL resample here would hide the very drift we need to see.
        let hardwareChannels = max(1, min(device.inputChannels, 8))
        var format = Self.interleavedFormat(
            sampleRate: device.nominalSampleRate, channels: hardwareChannels)
        guard AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else {
            AudioComponentInstanceDispose(unit)
            return nil
        }

        var maxFrames = UInt32(kMaxFrames)
        AudioUnitSetProperty(
            unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &maxFrames, UInt32(MemoryLayout<UInt32>.size))

        // Allocate the callback's working memory before it can ever run.
        let input = UnsafeMutablePointer<InputRT>.allocate(capacity: 1)
        input.initialize(to: InputRT())
        input.pointee.unit = unit
        input.pointee.channel = channel
        input.pointee.hardwareChannels = Int32(hardwareChannels)

        let listSize = MemoryLayout<AudioBufferList>.size
        let listRaw = UnsafeMutableRawPointer.allocate(
            byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        memset(listRaw, 0, listSize)
        input.pointee.bufferList = listRaw.assumingMemoryBound(to: AudioBufferList.self)

        let interleaved = UnsafeMutablePointer<Float>.allocate(
            capacity: kMaxFrames * hardwareChannels)
        interleaved.initialize(repeating: 0, count: kMaxFrames * hardwareChannels)
        input.pointee.interleaved = interleaved

        let mono = UnsafeMutablePointer<Float>.allocate(capacity: kMaxFrames)
        mono.initialize(repeating: 0, count: kMaxFrames)
        input.pointee.mono = mono

        var callback = AURenderCallbackStruct(
            inputProc: ocInputRenderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(input))
        guard AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
              AudioUnitInitialize(unit) == noErr else {
            interleaved.deallocate()
            mono.deallocate()
            listRaw.deallocate()
            input.deinitialize(count: 1)
            input.deallocate()
            AudioComponentInstanceDispose(unit)
            return nil
        }

        return input
    }

    private func teardownInputs() {
        for input in inputs {
            if let unit = input.pointee.unit {
                AudioOutputUnitStop(unit)
                AudioUnitUninitialize(unit)
                AudioComponentInstanceDispose(unit)
            }
            // Stop the callback before freeing anything it can touch.
            input.pointee.channel?.pointee.active = 0
            input.pointee.interleaved?.deallocate()
            input.pointee.mono?.deallocate()
            UnsafeMutableRawPointer(input.pointee.bufferList)?.deallocate()
            input.deinitialize(count: 1)
            input.deallocate()
        }
        inputs.removeAll()
    }

    // MARK: - Control surface

    /// Enqueues a parameter change for the render thread. Lock-free and safe to
    /// call as fast as a fader can be dragged.
    func setParameter(_ packedID: UInt32, _ value: Float) {
        _ = oc_param_queue_push(rt.pointee.paramQueue, packedID, value)
    }

    func meters(forChannel index: Int) -> ChannelMeters {
        guard index >= 0, index < Int(rt.pointee.channelCount) else { return ChannelMeters() }
        let channel = rt.pointee.channels + index
        let input = oc_channel_strip_input_meter(channel.pointee.strip)
        let output = oc_channel_strip_output_meter(channel.pointee.strip)
        var meters = ChannelMeters()
        meters.inputPeakDB = input.peak_db
        meters.inputRMSDB = input.rms_db
        meters.outputPeakDB = output.peak_db
        meters.outputRMSDB = output.rms_db
        meters.gateReductionDB = oc_channel_strip_gate_gr_db(channel.pointee.strip)
        meters.compressorReductionDB = oc_channel_strip_comp_gr_db(channel.pointee.strip)
        meters.connected = channel.pointee.active != 0
        return meters
    }

    func diagnostics() -> EngineDiagnostics {
        var diagnostics = EngineDiagnostics()
        diagnostics.running = running
        diagnostics.sinkAvailable = sinkAvailable
        diagnostics.droppedParameters = oc_param_queue_dropped_count(rt.pointee.paramQueue)
        for (index, device) in boundDevices.enumerated() {
            let channel = rt.pointee.channels + index
            diagnostics.underruns &+= channel.pointee.underruns
            diagnostics.overruns &+= channel.pointee.overruns
            diagnostics.perChannelRatioPPM[device.uid] = channel.pointee.ratioPPM
            diagnostics.perChannelFill[device.uid] = channel.pointee.fillFrames
            diagnostics.perChannelName[device.uid] = device.name
            // Read-and-clear, so each report describes the interval since the
            // last one rather than the worst case since launch.
            diagnostics.perChannelMaxInputGapUS[device.uid] = channel.pointee.maxInputGapUS
            channel.pointee.maxInputGapUS = 0
        }

        // Recency, not the lifetime total. See EngineDiagnostics for why.
        let total = UInt64(diagnostics.underruns) + UInt64(diagnostics.overruns)
        if total > lastDropoutTotal {
            lastDropoutTotal = total
            lastDropoutAt = Date()
        }
        if let at = lastDropoutAt {
            diagnostics.hasRecentDropout = -at.timeIntervalSinceNow < Self.dropoutWarningWindow
        }

        return diagnostics
    }

    /// How long the dropout warning stays lit after the last one, in seconds.
    /// Long enough that a single blip is readable, short enough that it is
    /// clearly about now and not about an hour ago.
    private static let dropoutWarningWindow: Double = 10

    // MARK: - Formats

    private static func nonInterleavedFormat(sampleRate: Double, channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)
    }

    private static func interleavedFormat(sampleRate: Double, channels: Int) -> AudioStreamBasicDescription {
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size * channels)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)
    }
}
