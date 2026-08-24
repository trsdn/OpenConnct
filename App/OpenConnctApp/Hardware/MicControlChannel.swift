import Foundation
import IOKit.hid

/// Reads the switches on a microphone's own body.
///
/// Some USB microphones carry a pad, a high-pass filter and other switches
/// physically on the case. Those act before the signal is ever digitised, so
/// this app cannot undo them and — established by measurement, see
/// `docs/device-control.md` — cannot set them either. What it can do is *know*
/// about them, which is enough to stop the app quietly applying a second
/// identical filter on top of the first.
///
/// Everything here is polling over a vendor-specific HID channel, which is a
/// deliberately conservative arrangement:
///
/// - It runs on its own thread with its own run loop, never the audio thread
///   and never the main thread. A single request takes milliseconds, and the
///   device drops requests that are not paced.
/// - It writes only to report identifiers in `writableReportIDs`, and that
///   check is in the one function that writes. Related products from the same
///   manufacturer accept firmware commands on another identifier with no
///   signature check, and "we have no reason to write there" is a weaker
///   guarantee than "this cannot".
/// - A device that does not answer is a non-event. Most microphones have no
///   such channel at all, so silence is the normal case, not an error.
final class MicControlChannel {

    /// Called on the main queue when a microphone's reported switches change.
    /// The identity is the caller's key, so it can be joined back to an audio
    /// device without this type knowing anything about CoreAudio.
    var onSwitchesChanged: ((USBDeviceIdentity, MicBodySwitches) -> Void)?

    /// Called on the main queue when a microphone with a control channel goes
    /// away, so its reported state can be dropped rather than left stale.
    var onDeviceLost: ((USBDeviceIdentity) -> Void)?

    /// The only report identifiers this type will ever write to.
    ///
    /// 4 opens the conversation — the device answers nothing at all until it is
    /// asked something there. 8 carries property queries. The identifier that
    /// carries firmware commands on sibling products is deliberately absent, and
    /// is unreachable rather than merely unused.
    private static let writableReportIDs: Set<UInt8> = [4, 8]

    private static let sessionReportID: UInt8 = 4
    private static let sessionLength = 28
    private static let sessionSelectors: [UInt8] = [0, 1, 2, 3]
    private static let queryReportID: UInt8 = 8
    private static let queryLength = 27
    private static let replyReportID: UInt8 = 7
    /// The first page of the HID vendor-defined range, which is where devices
    /// put anything the standard does not describe.
    private static let vendorUsagePage = 0xFF00

    /// One question every 40 ms, cycling. A full pass over four switches takes
    /// about a sixth of a second, which is faster than a hand can move a switch
    /// and slow enough that the device answers every time.
    private static let pollInterval: TimeInterval = 0.04

    /// Per-device state, owned by `thread` and touched from nowhere else.
    private final class Entry {
        let identity: USBDeviceIdentity
        var switches = MicBodySwitches()
        /// Which switches have been heard about at least once.
        ///
        /// Needed because "every switch is off" and "this device has never
        /// answered" produce identical state, and the interface has to tell them
        /// apart: one is a statement of fact, the other is a hedge. Without
        /// this, a microphone with everything switched off would never report,
        /// and would be indistinguishable from one that is not listening.
        var heard: Set<MicBodySwitches.Property> = []
        /// Whether a first complete reading has been handed over.
        var announced = false
        let buffer: UnsafeMutablePointer<UInt8>
        init(identity: USBDeviceIdentity, buffer: UnsafeMutablePointer<UInt8>) {
            self.identity = identity
            self.buffer = buffer
        }
    }

    private var thread: Thread?
    private var manager: IOHIDManager?
    private var timer: Timer?
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var devices: [ObjectIdentifier: IOHIDDevice] = [:]
    private var nextSelector = 0

    /// Devices seen but not yet opened.
    ///
    /// Nothing is opened or written from inside a matching callback. Doing so
    /// deadlocks against the HID subsystem's own locks: the write does not fail,
    /// it *times out*, five seconds at a time, and takes the run loop with it.
    /// That was measured, not anticipated. Adoption therefore happens on the
    /// next timer tick, outside any callback.
    private var pending: [IOHIDDevice] = []

    /// Requests waiting to go out, one per tick.
    ///
    /// A queue rather than direct sends because everything this talks to must be
    /// paced: asked back to back the device answers roughly a quarter of the
    /// questions and drops the rest. Session and polling traffic share the queue
    /// so that pacing is a property of the transport and not something each
    /// caller has to remember.
    private var outbox: [(device: IOHIDDevice, reportID: UInt8, payload: [UInt8])] = []

    /// The switches this type is interested in, in the order they are asked
    /// for. Only the four that are understood are polled; asking for the others
    /// would be traffic in exchange for nothing.
    private static let polled = MicBodySwitches.Property.allCases

    // MARK: - Lifecycle

    /// Starts looking for microphones with a control channel.
    ///
    /// Safe to call when none are attached, and safe to call on a machine where
    /// none ever will be: the thread sits idle and nothing is written.
    func start() {
        guard thread == nil else { return }
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "audio.openconnct.miccontrol"
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
    }

    /// Stops polling and releases the devices.
    ///
    /// Written so that it is safe to call from a deinit path: it does not wait
    /// for the thread, because a device that has stopped answering can hold a
    /// HID call for as long as it likes and blocking teardown on that would hang
    /// the app during quit.
    func stop() {
        guard let thread, !thread.isFinished else { return }
        perform(on: thread) { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
            if let manager = self?.manager {
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            self?.manager = nil
            for entry in self?.entries.values ?? [:].values { entry.buffer.deallocate() }
            self?.entries.removeAll()
            self?.devices.removeAll()
            self?.pending.removeAll()
            self?.outbox.removeAll()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        self.thread = nil
    }

    deinit { stop() }

    private func perform(on thread: Thread, _ work: @escaping () -> Void) {
        let box = BlockBox(work)
        box.perform(#selector(BlockBox.invoke), on: thread, with: nil, waitUntilDone: false)
    }

    /// `perform(_:on:with:waitUntilDone:)` needs an Objective-C selector, and a
    /// closure is not one. This is the smallest thing that bridges the two.
    private final class BlockBox: NSObject {
        private let work: () -> Void
        init(_ work: @escaping () -> Void) { self.work = work }
        @objc func invoke() { work() }
    }

    // MARK: - The thread

    private func run() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        // Vendor-defined devices only, and no vendor filter within that.
        //
        // Not a shortcut: it is what keeps this away from keyboards and pointing
        // devices. Matching those brings an app within reach of the input
        // monitoring consent prompt, and asking a user for permission to watch
        // their keystrokes in order to read a switch on a microphone would be
        // both alarming and unjustifiable.
        //
        // Any manufacturer's microphone that speaks this dialect on this page is
        // welcome; the descriptor check below is the real authority, and a
        // device that does not speak it simply never answers.
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: Self.vendorUsagePage,
        ] as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<MicControlChannel>.fromOpaque(ctx).takeUnretainedValue().noticed(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<MicControlChannel>.fromOpaque(ctx).takeUnretainedValue().remove(device)
        }, context)

        IOHIDManagerScheduleWithRunLoop(
            manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.current.add(timer, forMode: .default)
        self.timer = timer

        // Runs until `stop` stops it. `run()` on its own would spin even with
        // no sources; the timer guarantees there is always one.
        while self.manager != nil, !Thread.current.isCancelled {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.5))
        }
    }

    // MARK: - Devices

    /// Notes a device for later. Deliberately does no I/O — see `pending`.
    private func noticed(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        guard entries[key] == nil else { return }
        // A device that does not speak this dialect cannot answer, and asking it
        // would mean writing bytes to arbitrary hardware — keyboards, dongles,
        // capture cards — on the chance that it might be a microphone.
        guard declaresControlChannel(device) else { return }
        guard !pending.contains(where: { $0 === device }) else { return }
        pending.append(device)
    }

    private func adopt(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        guard entries[key] == nil else { return }
        guard let vendor = property(device, kIOHIDVendorIDKey) as? Int,
              let product = property(device, kIOHIDProductIDKey) as? Int
        else { return }
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        else { return }

        let identity = USBDeviceIdentity(
            vendorID: vendor,
            productID: product,
            serial: property(device, kIOHIDSerialNumberKey) as? String)

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        buffer.initialize(repeating: 0, count: 64)
        let entry = Entry(identity: identity, buffer: buffer)
        entries[key] = entry
        devices[key] = device

        IOHIDDeviceRegisterInputReportCallback(
            device, buffer, 64,
            { ctx, _, sender, _, reportID, report, length in
                guard let ctx, let sender else { return }
                let owner = Unmanaged<MicControlChannel>.fromOpaque(ctx).takeUnretainedValue()
                let device = Unmanaged<IOHIDDevice>
                    .fromOpaque(sender).takeUnretainedValue()
                owner.received(
                    from: device, reportID: UInt8(truncatingIfNeeded: reportID),
                    report: report, length: length)
            }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        openSession(device)
    }

    private func remove(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        pending.removeAll { $0 === device }
        outbox.removeAll { $0.device === device }
        guard let entry = entries.removeValue(forKey: key) else { return }
        devices.removeValue(forKey: key)
        entry.buffer.deallocate()
        let identity = entry.identity
        DispatchQueue.main.async { [weak self] in self?.onDeviceLost?(identity) }
    }

    /// Whether the device's own report descriptor declares the channels this
    /// speaks. Checked rather than assumed, because the alternative is writing
    /// bytes to arbitrary HID hardware — keyboards, mice, dongles — on the
    /// chance that it might be a microphone.
    private func declaresControlChannel(_ device: IOHIDDevice) -> Bool {
        guard let data = property(device, kIOHIDReportDescriptorKey) as? Data else { return false }
        var lengths: [UInt8: Int] = [:]
        var reportID: UInt8?
        var count: Int?
        var index = 0
        let bytes = [UInt8](data)

        // A minimal walk of the descriptor's short items: one byte of tag and
        // size, then that many bytes of value. Report count and report id are
        // both collected because the identifiers alone are not distinctive —
        // an unrelated capture card was found declaring the same three, and
        // writing to it would have been a write to hardware that never invited
        // the question. The payload lengths together with them are.
        while index < bytes.count {
            let head = bytes[index]
            let size = Int(head & 0x03)
            let length = size == 3 ? 4 : size
            guard index + length < bytes.count else { break }
            let tag = head & 0xFC
            let value = length == 1 ? Int(bytes[index + 1]) : nil
            switch tag {
            case 0x84: reportID = value.map { UInt8($0) }  // Report ID
            case 0x94: count = value                        // Report Count
            case 0x80, 0x90:                                // Input, Output
                if let reportID, let count { lengths[reportID] = count }
            default: break
            }
            index += 1 + length
        }

        return lengths[Self.sessionReportID] == Self.sessionLength
            && lengths[Self.queryReportID] == Self.queryLength
            && lengths[Self.replyReportID] == Self.queryLength
    }

    private func property(_ device: IOHIDDevice, _ key: String) -> Any? {
        IOHIDDeviceGetProperty(device, key as CFString)
    }

    // MARK: - Traffic

    /// The only place in this type that writes to a device.
    ///
    /// The report identifier goes in twice: once as the argument, and once as
    /// the first byte of the buffer with the length counting it. That is not
    /// belt and braces — omit the leading byte and every field lands one place
    /// out of position and the device refuses the request, which looks exactly
    /// like a permissions problem and is not one. See `docs/device-control.md`.
    @discardableResult
    private func send(_ device: IOHIDDevice, reportID: UInt8, payload: [UInt8]) -> Bool {
        guard Self.writableReportIDs.contains(reportID) else { return false }
        let framed = [reportID] + payload
        return IOHIDDeviceSetReport(
            device, kIOHIDReportTypeOutput, CFIndex(reportID), framed, framed.count)
            == kIOReturnSuccess
    }

    /// Asks the four opening questions. Until these are asked the device answers
    /// nothing at all, on any channel.
    private func openSession(_ device: IOHIDDevice) {
        for selector in Self.sessionSelectors {
            var payload = [UInt8](repeating: 0, count: Self.sessionLength)
            payload[0] = selector
            outbox.append((device, Self.sessionReportID, payload))
        }
    }

    /// Asks one device about one switch, then moves on.
    ///
    /// One question per tick rather than a burst. Asked back to back the device
    /// answers roughly a quarter of the questions and drops the rest, and a
    /// burst would also block this thread's run loop for as long as it took.
    private func tick() {
        // Adoption first, and one at a time: opening a device is the slowest
        // thing here and there is no reason for two of them to share a tick.
        if !pending.isEmpty {
            adopt(pending.removeFirst())
            return
        }
        if !outbox.isEmpty {
            let next = outbox.removeFirst()
            send(next.device, reportID: next.reportID, payload: next.payload)
            return
        }
        guard !devices.isEmpty else { return }
        let ordered = devices.keys.sorted { $0.hashValue < $1.hashValue }
        let total = ordered.count * Self.polled.count
        let step = nextSelector % total
        nextSelector = (nextSelector + 1) % total

        let device = devices[ordered[step / Self.polled.count]]
        let property = Self.polled[step % Self.polled.count]
        guard let device else { return }

        var payload = [UInt8](repeating: 0, count: Self.queryLength)
        payload[0] = property.rawValue
        outbox.append((device, Self.queryReportID, payload))
    }

    private func received(
        from device: IOHIDDevice, reportID: UInt8,
        report: UnsafeMutablePointer<UInt8>, length: CFIndex
    ) {
        guard reportID == Self.replyReportID, length >= 4 else { return }
        guard let entry = entries[ObjectIdentifier(device)] else { return }

        guard let property = MicBodySwitches.Property(rawValue: report[1]) else { return }
        // The third byte says whether the device understood the question. A
        // refusal carries no value, so acting on the bytes after it would be
        // reading noise.
        guard report[2] == 0x41 else { return }

        let before = entry.switches
        entry.switches.apply(property, value: report[3])
        entry.heard.insert(property)

        // Report a change, or the first complete reading — the latter because
        // an all-off microphone produces no changes and would otherwise never
        // be heard from at all.
        let complete = entry.heard.count == Self.polled.count
        let firstComplete = complete && !entry.announced
        guard entry.switches != before || firstComplete else { return }
        if complete { entry.announced = true }

        let identity = entry.identity
        let switches = entry.switches
        DispatchQueue.main.async { [weak self] in
            self?.onSwitchesChanged?(identity, switches)
        }
    }
}
