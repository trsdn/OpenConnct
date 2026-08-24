import XCTest
@testable import OpenConnctControl

/// The join between an audio device and the same physical device on the HID
/// bus. A wrong match here would attribute one microphone's switch positions to
/// another, so the cases that must fail are tested at least as carefully as the
/// ones that must succeed.
final class USBDeviceIdentityTests: XCTestCase {

    // Real strings, from three USB audio devices by three manufacturers and
    // from the devices that must produce nothing. Copied verbatim from a live
    // system rather than invented, because the format is undocumented and an
    // invented example only tests the parser against itself.
    private let condenser = (
        uid: "AppleUSBAudioEngine:Some Vendor:Some Condenser:9EB56A4F:1,2",
        model: "Some Condenser:19F7:0015")
    private let shotgun = (
        uid: "AppleUSBAudioEngine:Some Vendor:Some Shotgun:40A0E9F4:1,2",
        model: "Some Shotgun:19F7:001A")
    private let capture = (
        uid: "AppleUSBAudioEngine:Other Vendor:Capture Card:A29YB44930G2O8:3",
        model: "Capture Card:0FD9:00A1")

    func testParsesVendorProductAndSerial() {
        let id = USBDeviceIdentity.parse(uid: condenser.uid, modelUID: condenser.model)
        XCTAssertEqual(id?.vendorID, 0x19F7)
        XCTAssertEqual(id?.productID, 0x0015)
        XCTAssertEqual(id?.serial, "9EB56A4F")
    }

    func testParsesADeviceFromAnotherManufacturer() {
        let id = USBDeviceIdentity.parse(uid: capture.uid, modelUID: capture.model)
        XCTAssertEqual(id?.vendorID, 0x0FD9)
        XCTAssertEqual(id?.productID, 0x00A1)
        XCTAssertEqual(id?.serial, "A29YB44930G2O8")
    }

    /// Built-in and virtual devices have no USB identity, and there are more of
    /// them on a typical machine than real microphones. Returning a wrong answer
    /// for these would be worse than returning none.
    func testNonUSBDevicesHaveNoIdentity() {
        XCTAssertNil(USBDeviceIdentity.parse(
            uid: "BuiltInHeadphoneInputDevice", modelUID: "Codec Input"))
        XCTAssertNil(USBDeviceIdentity.parse(
            uid: "OpenConnctMic_UID", modelUID: "OpenConnctMic_ModelUID"))
        XCTAssertNil(USBDeviceIdentity.parse(
            uid: "SomeOther_UID", modelUID: "SomeOther_ModelUID"))
    }

    /// A model name ending in something that happens to parse as hexadecimal is
    /// the realistic way this parser gets a wrong answer, so the length check
    /// that prevents it is tested directly.
    func testRejectsFieldsThatAreNotFourHexDigits() {
        XCTAssertNil(USBDeviceIdentity.parse(
            uid: "AppleUSBAudioEngine:V:Mic ABC:DEF:1", modelUID: "Mic:ABC:DEF"))
        XCTAssertNil(USBDeviceIdentity.parse(
            uid: "AppleUSBAudioEngine:V:Mic:S:1", modelUID: "Mic:19F7:00155"))
        XCTAssertNil(USBDeviceIdentity.parse(
            uid: "AppleUSBAudioEngine:V:Mic:S:1", modelUID: "Mic:ZZZZ:0015"))
    }

    func testMatchesTheSameDevice() {
        let id = USBDeviceIdentity.parse(uid: condenser.uid, modelUID: condenser.model)
        XCTAssertTrue(id!.matches(vendorID: 0x19F7, productID: 0x0015, serial: "9EB56A4F"))
    }

    /// Two microphones from one manufacturer differ only in product id, and this
    /// is the confusion that would silently show one device's switches under the
    /// other's name.
    func testDoesNotMatchASiblingProduct() {
        let id = USBDeviceIdentity.parse(uid: condenser.uid, modelUID: condenser.model)
        XCTAssertFalse(id!.matches(vendorID: 0x19F7, productID: 0x001A, serial: "40A0E9F4"))
    }

    /// Two *identical* microphones can only be told apart by serial, so this is
    /// the case the serial exists for.
    func testDoesNotMatchAnIdenticalDeviceWithADifferentSerial() {
        let id = USBDeviceIdentity.parse(uid: condenser.uid, modelUID: condenser.model)
        XCTAssertFalse(id!.matches(vendorID: 0x19F7, productID: 0x0015, serial: "DEADBEEF"))
    }

    /// A device that reports no serial on one of the two buses must still match,
    /// or it would be dropped entirely. This is the deliberate asymmetry.
    func testMatchesWhenTheOtherSideReportsNoSerial() {
        let id = USBDeviceIdentity.parse(uid: condenser.uid, modelUID: condenser.model)
        XCTAssertTrue(id!.matches(vendorID: 0x19F7, productID: 0x0015, serial: nil))
    }

    func testSerialComparisonIgnoresCase() {
        let id = USBDeviceIdentity.parse(uid: condenser.uid, modelUID: condenser.model)
        XCTAssertTrue(id!.matches(vendorID: 0x19F7, productID: 0x0015, serial: "9eb56a4f"))
    }

    func testTwoDevicesFromOneManufacturerParseDistinctly() {
        let a = USBDeviceIdentity.parse(uid: condenser.uid, modelUID: condenser.model)
        let b = USBDeviceIdentity.parse(uid: shotgun.uid, modelUID: shotgun.model)
        XCTAssertNotEqual(a, b)
    }
}
