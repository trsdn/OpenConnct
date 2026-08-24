/// A USB audio device's vendor, product and serial, recovered from the two
/// strings CoreAudio publishes about it.
///
/// This exists so that an audio device can be matched to the *same physical
/// device* on another bus — specifically to its HID interface, which is where a
/// microphone's own switches are readable. CoreAudio and IOKit have no shared
/// identifier, so the join has to be made out of what both sides happen to
/// expose.
///
/// The parsing is deliberately dumb and total: any string that does not look
/// right yields `nil` rather than a guess. A wrong match here would attribute
/// one microphone's switch positions to another, which is worse than no match
/// at all.
public struct USBDeviceIdentity: Equatable, Hashable, Sendable {
    public let vendorID: Int
    public let productID: Int
    /// Absent on devices that do not report one. Two identical microphones on
    /// one machine can only be told apart by this, so a `nil` serial means the
    /// match is by model alone and is only safe when exactly one such device is
    /// present.
    public let serial: String?

    public init(vendorID: Int, productID: Int, serial: String?) {
        self.vendorID = vendorID
        self.productID = productID
        self.serial = serial
    }

    /// Recovers the identity from CoreAudio's device UID and model UID.
    ///
    /// The two strings carry different halves of the answer, which is why both
    /// are needed:
    ///
    ///     modelUID  "Some Microphone:19F7:0015"
    ///     uid       "AppleUSBAudioEngine:Some Vendor:Some Microphone:9EB56A4F:1,2"
    ///
    /// The model UID ends in vendor and product as four hex digits each. The
    /// device UID carries the serial in its second-to-last colon-separated
    /// field. Neither format is documented, so both are treated as a convention
    /// that may not hold: a device whose strings do not match this shape simply
    /// has no identity, and every caller must already cope with that because
    /// most audio devices are not USB at all.
    ///
    /// Verified against three unrelated USB audio devices from three
    /// manufacturers, and against the built-in and virtual devices, which
    /// correctly produce `nil`.
    public static func parse(uid: String, modelUID: String) -> USBDeviceIdentity? {
        let modelParts = modelUID.split(separator: ":", omittingEmptySubsequences: false)
        guard modelParts.count >= 3,
              let productID = Int(modelParts[modelParts.count - 1], radix: 16),
              let vendorID = Int(modelParts[modelParts.count - 2], radix: 16),
              // Four hex digits each. A model name that happens to end in
              // something hex-looking would otherwise be read as an identity.
              modelParts[modelParts.count - 1].count == 4,
              modelParts[modelParts.count - 2].count == 4
        else { return nil }

        let uidParts = uid.split(separator: ":", omittingEmptySubsequences: false)
        var serial: String?
        if uidParts.count >= 2 {
            let candidate = String(uidParts[uidParts.count - 2])
            if !candidate.isEmpty { serial = candidate }
        }
        return USBDeviceIdentity(vendorID: vendorID, productID: productID, serial: serial)
    }

    /// Whether this identity and a device found on another bus are the same
    /// physical object.
    ///
    /// Serials are compared when both sides have one, and ignored when either
    /// does not. That asymmetry is the point: requiring a serial would drop
    /// devices that report none, and ignoring it would confuse two identical
    /// microphones. Comparison is case-insensitive because the two buses have
    /// been observed to disagree on case for the same device.
    public func matches(vendorID: Int, productID: Int, serial otherSerial: String?) -> Bool {
        guard self.vendorID == vendorID, self.productID == productID else { return false }
        guard let mine = serial, let theirs = otherSerial else { return true }
        return mine.lowercased() == theirs.lowercased()
    }
}
