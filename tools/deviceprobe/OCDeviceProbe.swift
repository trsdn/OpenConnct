import Foundation
import IOKit
import IOKit.hid
import AppKit
import SwiftUI

// Inspects the vendor control channel that some USB microphones expose beside
// their audio interfaces.
//
// Why this is a separate tool rather than code in the app: the meaning of the
// bytes on that channel is not documented by anyone, and the only way to learn
// it is to change one thing on the device and watch which byte moves. That is
// an experiment, not a feature, and an experiment that talks to hardware over
// an undocumented protocol should be run deliberately, by a person, with the
// output in front of them — not by an application on launch.
//
// The app does not link this. Nothing here runs unless it is run on purpose.

// MARK: - Safety

/// Write channels this program is permitted to use.
///
/// The report descriptor exposes four request/response channel pairs. On the
/// pair with the smallest payload — request channel 2 — sibling products from
/// the same vendor are documented to accept single ASCII letters that put the
/// device into firmware update mode and then trigger a flash. There is no
/// reason for this tool to go near that, and "no reason to" is a weaker
/// guarantee than "cannot", so the permitted set is a constant and every write
/// is checked against it.
///
/// Channel 4 is included because the device ignores everything until it is
/// asked something there: the manufacturer's own application queries it four
/// times at startup, and only afterwards does the device answer anything else.
/// That was established by watching, not guessed — see docs/device-control.md.
private let writableReportIDs: Set<UInt8> = [4, 8]

// MARK: - Protocol shape, as measured

/// Reply channel that carries the device's property dump.
private let propertyReplyReportID: UInt8 = 7
/// The request channel paired with it, taken from the device's own report
/// descriptor rather than assumed.
private let propertyRequestReportID: UInt8 = 8
/// Payload length the descriptor declares for that request channel.
private let propertyRequestLength = 27

/// The channel the manufacturer's application queries at startup, and the
/// length its descriptor declares for it. Until something is asked here the
/// device answers nothing at all, on any channel.
private let sessionRequestReportID: UInt8 = 4
private let sessionRequestLength = 28
/// The selectors the application was observed to ask for, in order.
private let sessionSelectors: [UInt8] = [0, 1, 2, 3]

/// Asks the device the same four opening questions the manufacturer's
/// application asks at startup.
///
/// This is not yet enough. Asked cold, the device refuses the first question
/// and ignores the rest, where the same selectors answered with data for the
/// manufacturer's application. So the selectors are right and something else
/// about the request is not — most likely its payload, which cannot be read
/// off the wire with an input-report callback because that only sees what the
/// device sends, never what another process wrote.
///
/// It is kept because the refusal is itself the finding: cold, the device says
/// nothing at all, and after this it says "no". That is the difference between
/// a device that is asleep and a device that is declining, and it is where the
/// next attempt should start. See docs/device-control.md.
private func openSession(_ device: IOHIDDevice) {
    for selector in sessionSelectors {
        var request = [UInt8](repeating: 0, count: sessionRequestLength)
        request[0] = selector
        send(device, reportID: sessionRequestReportID, payload: request)
        Thread.sleep(forTimeInterval: 0.02)
    }
}

/// Third byte of every reply seen so far: 'A' for accepted, 'N' for refused.
private let ack: UInt8 = 0x41
private let nak: UInt8 = 0x4E

/// Vendor whose control channel this understands. A number, not a name: this is
/// a wire identifier in the same sense as a file format's magic bytes.
private let vendorID = 0x19F7

// MARK: - Formatting

private func hex(_ bytes: ArraySlice<UInt8>) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

private func trimmingTrailingZeros(_ bytes: [UInt8]) -> [UInt8] {
    var out = bytes
    while let last = out.last, last == 0 { out.removeLast() }
    return out
}

private func property(_ device: IOHIDDevice, _ key: String) -> Any? {
    IOHIDDeviceGetProperty(device, key as CFString)
}

private func describe(_ device: IOHIDDevice) -> String {
    let vid = (property(device, kIOHIDVendorIDKey) as? Int) ?? 0
    let pid = (property(device, kIOHIDProductIDKey) as? Int) ?? 0
    let name = (property(device, kIOHIDProductKey) as? String) ?? "?"
    return String(format: "%04X:%04X  %@", vid, pid, name)
}

// MARK: - Report descriptor

/// Decodes the short-item report descriptor far enough to show the channel
/// layout. Not a general decoder — it covers the items these devices use.
private func decodeDescriptor(_ bytes: [UInt8]) {
    var index = 0
    var depth = 1
    let tagNames: [UInt8: [UInt8: String]] = [
        0: [0x8: "Input", 0x9: "Output", 0xB: "Feature",
            0xA: "Collection", 0xC: "End Collection"],
        1: [0x0: "Usage Page", 0x1: "Logical Minimum", 0x2: "Logical Maximum",
            0x7: "Report Size", 0x8: "Report ID", 0x9: "Report Count"],
        2: [0x0: "Usage", 0x1: "Usage Minimum", 0x2: "Usage Maximum"],
    ]
    while index < bytes.count {
        let item = bytes[index]
        let size = (item & 0x03) == 3 ? 4 : Int(item & 0x03)
        let type = (item >> 2) & 0x03
        let tag = (item >> 4) & 0x0F
        var value = 0
        for k in 0..<size where index + 1 + k < bytes.count {
            value |= Int(bytes[index + 1 + k]) << (8 * k)
        }
        let name = tagNames[type]?[tag] ?? String(format: "type %d tag %X", type, tag)
        if name == "End Collection" { depth = max(1, depth - 1) }
        var suffix = ""
        if name == "Usage Page" && value >= 0xFF00 { suffix = "  (vendor-defined)" }
        print(String(repeating: "  ", count: depth)
            + String(format: "%-18@ 0x%02X%@", name as NSString, value, suffix))
        if name == "Collection" { depth += 1 }
        index += 1 + size
    }
}

// MARK: - Device access

private func matchingDevices(pid: Int?) -> [IOHIDDevice] {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    var criteria: [String: Any] = [kIOHIDVendorIDKey: vendorID]
    if let pid { criteria[kIOHIDProductIDKey] = pid }
    IOHIDManagerSetDeviceMatching(manager, criteria as CFDictionary)
    IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
    return set.sorted {
        ((property($0, kIOHIDProductIDKey) as? Int) ?? 0)
            < ((property($1, kIOHIDProductIDKey) as? Int) ?? 0)
    }
}

/// The only place in this program that writes to a device.
@discardableResult
private func send(_ device: IOHIDDevice, reportID: UInt8, payload: [UInt8]) -> Bool {
    guard writableReportIDs.contains(reportID) else {
        FileHandle.standardError.write(
            "refusing to write report \(reportID): not in the permitted set\n"
                .data(using: .utf8)!)
        return false
    }
    let result = IOHIDDeviceSetReport(
        device, kIOHIDReportTypeOutput, CFIndex(reportID), payload, payload.count)
    if result != kIOReturnSuccess {
        print(String(format: "   write failed: 0x%08X", result))
        return false
    }
    return true
}

// MARK: - Commands

private func listDevices() {
    let devices = matchingDevices(pid: nil)
    guard !devices.isEmpty else {
        print("No device with a control channel from vendor "
            + String(format: "0x%04X", vendorID) + " is connected.")
        return
    }
    print("Control channels found: \(devices.count)")
    for device in devices {
        let usagePage = (property(device, kIOHIDPrimaryUsagePageKey) as? Int) ?? 0
        let input = (property(device, kIOHIDMaxInputReportSizeKey) as? Int) ?? 0
        let output = (property(device, kIOHIDMaxOutputReportSizeKey) as? Int) ?? 0
        print("  " + describe(device))
        print(String(format: "      usage page 0x%04X   max report in %d, out %d",
                     usagePage, input, output))
    }
}

private func showDescriptors() {
    for device in matchingDevices(pid: nil) {
        print("\n===== \(describe(device)) =====")
        guard let data = property(device, kIOHIDReportDescriptorKey) as? Data else {
            print("  device did not return a report descriptor")
            continue
        }
        let bytes = [UInt8](data)
        print("  \(bytes.count) bytes: \(hex(bytes[...]))")
        decodeDescriptor(bytes)
    }
}

private final class SeenValues {
    var values: [UInt8: [UInt8]] = [:]
}

private final class WatchContext {
    let productID: Int
    let seen: SeenValues
    let started: Date
    /// Every report the device sent, on any channel. Silence and "nothing
    /// changed" look identical on screen, and they mean opposite things: one is
    /// a device that is not answering at all, the other is a device that is
    /// answering and has nothing new to say. Counting separates them.
    var repliesReceived = 0
    init(productID: Int, seen: SeenValues, started: Date) {
        self.productID = productID
        self.seen = seen
        self.started = started
    }
}

/// Watches the property block and prints only what changes.
///
/// This is the mode the tool exists for. Run it, then move one switch on the
/// microphone. Whichever line appears is that switch.
private func watch(pid: Int?, passive: Bool, seconds: Double) {
    let devices = matchingDevices(pid: pid)
    guard !devices.isEmpty else { print("No matching device."); return }
    let started = Date()
    var contexts: [WatchContext] = []
    var writesSent = 0
    var writesFailed = 0

    for device in devices {
        let productID = (property(device, kIOHIDProductIDKey) as? Int) ?? 0
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if opened != kIOReturnSuccess {
            print(String(format: "%04X: could not open the control channel (0x%08X)",
                         productID, opened))
        }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        buffer.initialize(repeating: 0, count: 64)
        let box = WatchContext(productID: productID, seen: SeenValues(), started: started)
        contexts.append(box)
        let context = Unmanaged.passRetained(box).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, buffer, 64,
            { ctx, _, _, _, reportID, report, length in
                guard let ctx else { return }
                let state = Unmanaged<WatchContext>.fromOpaque(ctx).takeUnretainedValue()
                state.repliesReceived += 1
                var bytes: [UInt8] = []
                for i in 0..<length { bytes.append(report[i]) }
                let elapsed = Date().timeIntervalSince(state.started)

                guard UInt8(reportID) == propertyReplyReportID, bytes.count >= 4 else {
                    // Anything on another channel is printed raw; that is how the
                    // remaining channels will eventually be identified.
                    print(String(format: "%7.2fs  %04X  channel %d: %@",
                                 elapsed, state.productID, reportID, hex(bytes[...])))
                    return
                }
                let id = bytes[1]
                let status = bytes[2]
                let value = trimmingTrailingZeros(Array(bytes[3...]))
                let previous = state.seen.values[id]
                guard previous != value else { return }
                let statusText = status == ack ? "ok" : (status == nak ? "REFUSED" : "?")
                let wasText = previous.map { "  (was \(hex($0[...])))" } ?? ""
                print(String(format: "%7.2fs  %04X  property %-3d %-7@ = %@%@",
                             elapsed, state.productID, Int(id), statusText as NSString,
                             value.isEmpty ? "0" : hex(value[...]), wasText))
                state.seen.values[id] = value
            }, context)
        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    if passive {
        print("Listening only — nothing is sent to the device. \(Int(seconds))s.")
    } else {
        for device in devices { openSession(device) }
        print("Polling the property block for \(Int(seconds))s.")
        print("Move one switch on the microphone; the line that appears is that switch.")
    }

    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if !passive {
            // The request that was observed to produce a full property dump.
            var request = [UInt8](repeating: 0, count: propertyRequestLength)
            request[0] = 0x00
            for device in devices {
                writesSent += 1
                if !send(device, reportID: propertyRequestReportID, payload: request) {
                    writesFailed += 1
                }
            }
        }
        CFRunLoopRunInMode(.defaultMode, passive ? 1.0 : 0.5, false)
    }
    print("Finished.")
    if !passive {
        print("Requests sent: \(writesSent), of which \(writesFailed) were rejected.")
    }
    for box in contexts {
        print(String(format: "%04X: %d replies received.", box.productID, box.repliesReceived))
        guard box.repliesReceived == 0 else { continue }
        if passive {
            print("      Nothing was sent to it and it volunteered nothing. Expected:")
            print("      this device only speaks when spoken to.")
        } else {
            print("      The device accepted the requests and answered none of them.")
            print("      That is a device that is ignoring us, not a device with")
            print("      nothing to report. See docs/device-control.md.")
        }
    }
}

// MARK: - Live window

/// One property of one device, as shown on screen.
private struct MonitorRow: Identifiable {
    let id: String
    let productID: Int
    let property: UInt8
    var value: String
    var previous: String?
    var changes = 0
    var lit = false
    /// What the user decided this property is. Typed in the window, so the
    /// person watching the microphone is the one who names it.
    var label = ""
}

private final class MonitorModel: ObservableObject {
    @Published var rows: [MonitorRow] = []
    @Published var replies = 0
    @Published var otherChannels: [String] = []

    /// Highlights fade on a timer rather than on the next change, so a value
    /// that flicks out and back — a button that is pressed and released — is
    /// still visible to someone who blinked.
    func apply(productID: Int, property: UInt8, value: String) {
        let key = String(format: "%04X-%d", productID, Int(property))
        replies += 1
        if let index = rows.firstIndex(where: { $0.id == key }) {
            guard rows[index].value != value else { return }
            rows[index].previous = rows[index].value
            rows[index].value = value
            rows[index].changes += 1
            rows[index].lit = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let i = self.rows.firstIndex(where: { $0.id == key }) else { return }
                self.rows[i].lit = false
            }
        } else {
            rows.append(MonitorRow(id: key, productID: productID, property: property, value: value))
            rows.sort { ($0.productID, $0.property) < ($1.productID, $1.property) }
        }
    }

    /// A markdown table of whatever has been worked out, for pasting into the
    /// issue. The point of the window is to produce this.
    func findings() -> String {
        var text = "| device | property | value | changes | what it is |\n"
        text += "|---|---|---|---|---|\n"
        for row in rows {
            let name = row.label.isEmpty ? "not identified" : row.label
            text += String(format: "| %04X | %d | %@ | %d | %@ |\n",
                           row.productID, Int(row.property), row.value, row.changes, name)
        }
        return text
    }
}

private final class MonitorContext {
    let productID: Int
    let model: MonitorModel
    init(productID: Int, model: MonitorModel) {
        self.productID = productID
        self.model = model
    }
}

private struct MonitorRowView: View {
    let row: MonitorRow

    private var background: Color {
        row.lit ? Color.green.opacity(0.30) : Color.white.opacity(0.04)
    }

    var body: some View {
        let previous = row.previous.map { "was \($0)" } ?? " "
        HStack(spacing: 12) {
            Text(String(format: "%04X", row.productID))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .leading)
            Text("\(row.property)")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .frame(width: 24, alignment: .trailing)
            Text(row.value)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .frame(width: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(previous).font(.system(size: 10, design: .monospaced))
                Text("\(row.changes) changes").font(.system(size: 10))
            }
            .foregroundColor(.secondary)
            .frame(width: 90, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(background))
    }
}

private struct MonitorView: View {
    @ObservedObject var model: MonitorModel
    @State private var startedAt = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Move one control on the microphone.")
                .font(.system(size: 14, weight: .semibold))
            Text("The row that lights up is that control. Name it, then do the next one.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            if model.replies == 0 {
                Text("The microphone is not answering. It only responds once the "
                    + "manufacturer's own application has opened a session with it. "
                    + "Start that application, leave it running, and this window "
                    + "will fill in.")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(spacing: 4) {
                    ForEach($model.rows) { $row in
                        HStack(spacing: 8) {
                            MonitorRowView(row: row)
                            TextField("what is it?", text: $row.label)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 170)
                        }
                    }
                }
            }

            HStack {
                Button("Copy findings") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.findings(), forType: .string)
                }
                Spacer()
                Text("\(model.replies) replies")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 380)
    }
}

/// Shows the property block in a window, live.
///
/// Same requests as `--watch`, same permitted write channel; only the output is
/// different. Reading a scrolling log while also looking at a microphone is a
/// job for two people, and there is only one of the user.
private func monitor(pid: Int?) {
    let devices = matchingDevices(pid: pid)
    guard !devices.isEmpty else { print("No matching device."); return }

    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let model = MonitorModel()

    for device in devices {
        let productID = (property(device, kIOHIDProductIDKey) as? Int) ?? 0
        _ = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        buffer.initialize(repeating: 0, count: 64)
        let context = Unmanaged.passRetained(
            MonitorContext(productID: productID, model: model)).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, buffer, 64,
            { ctx, _, _, _, reportID, report, length in
                guard let ctx else { return }
                let state = Unmanaged<MonitorContext>.fromOpaque(ctx).takeUnretainedValue()
                var bytes: [UInt8] = []
                for i in 0..<length { bytes.append(report[i]) }
                guard UInt8(reportID) == propertyReplyReportID, bytes.count >= 4 else {
                    state.model.replies += 1
                    return
                }
                let trimmed = trimmingTrailingZeros(Array(bytes[3...]))
                let text = trimmed.isEmpty ? "0" : hex(trimmed[...])
                state.model.apply(productID: state.productID, property: bytes[1], value: text)
            }, context)
        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
        var request = [UInt8](repeating: 0, count: propertyRequestLength)
        request[0] = 0x00
        for device in devices {
            send(device, reportID: propertyRequestReportID, payload: request)
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false)
    window.title = "Control channel"
    window.contentView = NSHostingView(rootView: MonitorView(model: model))
    window.center()
    window.makeKeyAndOrderFront(nil)
    application.activate(ignoringOtherApps: true)
    application.run()
}

// MARK: - Entry

private func usage() {
    print("""
    Inspects the vendor control channel on connected USB microphones.

      --list                show the control channels that are present
      --descriptor          print and decode each device's report descriptor
      --watch               print property changes as they happen
      --window              the same, in a window, so it can be watched while
                            operating the microphone with both hands
      --passive             with --watch: listen only, never write
      --pid 0xNNNN          restrict --watch or --window to one product
      --seconds N           how long --watch runs (default 60)

    This tool only ever writes to one request channel, and never to the one that
    carries firmware commands on related products.
    """)
}

let arguments = CommandLine.arguments
var selectedPID: Int?
if let i = arguments.firstIndex(of: "--pid"), i + 1 < arguments.count {
    let text = arguments[i + 1]
    selectedPID = text.hasPrefix("0x") ? Int(text.dropFirst(2), radix: 16) : Int(text)
}
var duration = 60.0
if let i = arguments.firstIndex(of: "--seconds"), i + 1 < arguments.count,
   let value = Double(arguments[i + 1]) {
    duration = value
}

if arguments.contains("--descriptor") {
    showDescriptors()
} else if arguments.contains("--window") {
    monitor(pid: selectedPID)
} else if arguments.contains("--watch") {
    watch(pid: selectedPID, passive: arguments.contains("--passive"), seconds: duration)
} else if arguments.contains("--list") {
    listDevices()
} else {
    usage()
}
