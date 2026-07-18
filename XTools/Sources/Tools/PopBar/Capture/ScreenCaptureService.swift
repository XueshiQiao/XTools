import CoreGraphics
import AppKit

/// Grabs pixels off the screen for OCR. Works per-display so the crop math stays
/// correct on multi-monitor / negative-origin layouts (a global-coordinate
/// capture would flip y across displays).
enum ScreenCaptureService {

    private static let log = FileLog("PopBar.OCR")

    /// Capture `globalCocoaRect` (GLOBAL Cocoa coordinates: bottom-left origin, y up —
    /// the same space as `NSScreen.frame` / `NSEvent.mouseLocation`) from `screen`.
    /// Returns a CGImage at native pixel resolution, or nil (no permission / failure).
    static func capture(globalCocoaRect rect: CGRect, on screen: NSScreen) -> CGImage? {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(num.uint32Value)

        // Capture the WHOLE display, then crop locally. `CGDisplayCreateImage` is
        // deprecated on macOS 14 but still functional and requires the Screen
        // Recording permission.
        // TODO: SCScreenshotManager on macOS 14+.
        guard let full = CGDisplayCreateImage(displayID) else { return nil }

        // Convert the global Cocoa rect to this display's LOCAL top-left-origin
        // POINT rect (flip y within the screen), then scale to native pixels.
        let localX = rect.minX - screen.frame.minX
        let localTop = screen.frame.maxY - rect.maxY
        let scale = screen.backingScaleFactor
        var px = CGRect(
            x: localX * scale,
            y: localTop * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral

        // Clamp to the display's pixel bounds; bail if nothing overlaps.
        let bounds = CGRect(x: 0, y: 0, width: full.width, height: full.height)
        px = px.intersection(bounds)
        guard !px.isEmpty else { return nil }

        let cropped = full.cropping(to: px)
        log.info("captured \(Int(px.width))x\(Int(px.height)) px")
        return cropped
    }
}
