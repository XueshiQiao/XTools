import Foundation

/// Vendor ids for the Razer Naga family. `0x1532` is Razer; `0x068E` shows up on
/// the Bluetooth path. The Naga exposes several HID interfaces (mouse + keyboard);
/// the numbered side buttons come from a keyboard-usage interface, which the
/// listener filters to by keeping only keyboard-page usages.
enum NagaDevice {
    static let razerVendorID = 0x1532
    static let btVendorID = 0x068E
}
