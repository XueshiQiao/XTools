import AppKit

/// The Screenshot-OCR front-step coordinator: a global hotkey puts up a drag-select
/// overlay, the chosen region is OCR'd, and the recognized text is (optionally) copied
/// to the clipboard and shown in the SAME PopBar capsule via `PopBarWindowManager` —
/// so every existing action runs on the OCR'd text exactly like a normal selection.
///
/// Deliberately INDEPENDENT of PopBar's text-selection monitor: it needs only Screen
/// Recording (checked at capture time), not Accessibility, so it works even when the
/// selection popup is off. Main-thread only by convention (hotkey callback + all UI).
final class ScreenOCRController {

    private static let log = FileLog("PopBar.OCR")

    private let windows: PopBarWindowManager
    private let actionStore: ActionStore
    private var hotKey: GlobalHotKey?
    /// Guards against putting up a second overlay while one is already on screen.
    private var capturing = false
    /// Held for the duration of one capture so the overlay controller (which owns the
    /// per-screen overlay windows) isn't deallocated before its completion fires.
    private var regionSelector: RegionSelectionController?
    /// Bumped per capture so a slow OCR completion from an earlier capture can't
    /// overwrite the clipboard/capsule after a newer capture has superseded it.
    private var captureGeneration = 0

    init(windows: PopBarWindowManager, actionStore: ActionStore) {
        self.windows = windows
        self.actionStore = actionStore
    }

    /// Whether the global hotkey is currently registered.
    var isEnabled: Bool { hotKey != nil }

    // MARK: - Lifecycle (call on main)

    /// Register the hotkey only if the user opted in (used at app launch).
    func startIfEnabled() {
        guard PopBarPreferences.screenOCREnabled else {
            Self.log.info("OCR disabled — not registering hotkey")
            return
        }
        _ = start()
    }

    /// Register the global hotkey from prefs. Returns false if registration failed
    /// (the combo is already taken system-wide) so the caller can surface it.
    @discardableResult
    func start() -> Bool {
        if hotKey != nil { return true }
        let combo = PopBarPreferences.screenOCRHotKey
        hotKey = GlobalHotKey(combo: combo) { [weak self] in self?.triggerCapture() }
        guard hotKey != nil else {
            Self.log.warn("failed to register OCR hotkey \(combo.display) — likely taken")
            return false
        }
        Self.log.info("OCR hotkey registered: \(combo.display)")
        return true
    }

    /// Unregister the hotkey (feature disabled / tool shutdown).
    func stop() {
        hotKey?.invalidate()
        hotKey = nil
        Self.log.info("OCR hotkey unregistered")
    }

    /// Persist + (re)register a new hotkey. On a registration failure the PREVIOUS
    /// combo is kept registered (never leaves the user with no working hotkey) and the
    /// new combo is NOT persisted. Returns false in that case.
    @discardableResult
    func setHotKey(_ combo: KeyCombo) -> Bool {
        guard PopBarPreferences.screenOCREnabled else {
            // Nothing registered yet — just store it; `start()` will use it when enabled.
            PopBarPreferences.screenOCRHotKey = combo
            return true
        }
        hotKey?.invalidate()
        hotKey = GlobalHotKey(combo: combo) { [weak self] in self?.triggerCapture() }
        if hotKey == nil {
            Self.log.warn("failed to register new OCR hotkey \(combo.display) — reverting to previous")
            let previous = PopBarPreferences.screenOCRHotKey
            hotKey = GlobalHotKey(combo: previous) { [weak self] in self?.triggerCapture() }
            return false
        }
        PopBarPreferences.screenOCRHotKey = combo
        Self.log.info("OCR hotkey re-registered: \(combo.display)")
        return true
    }

    // MARK: - Capture → OCR → capsule

    /// The full front-step flow, fired by the hotkey. Runs entirely on main except the
    /// Vision OCR (which hops back to main before touching any window).
    func triggerCapture() {
        guard !capturing else { return }
        guard ScreenRecordingAuthorizer.isAuthorized else {
            // First press ever shows the system prompt; a previously-denied user is sent
            // to System Settings. Either way we don't put up the overlay yet.
            Self.log.warn("no Screen Recording permission — requesting / guiding to settings")
            if !ScreenRecordingAuthorizer.request() {
                ScreenRecordingAuthorizer.openSettings()
            }
            return
        }
        capturing = true
        captureGeneration &+= 1
        let generation = captureGeneration
        let selector = RegionSelectionController()
        regionSelector = selector
        selector.begin { [weak self] selection in
            guard let self else { return }
            self.regionSelector = nil
            self.capturing = false
            guard let selection else { return }   // cancelled (Esc / right-click / too small)

            let rect = selection.globalCocoaRect
            // Anchor the capsule at the region's TOP-center, so it floats just above the
            // selection (matching the text-selection capsule which sits above its anchor).
            let anchor = CGPoint(x: rect.midX, y: rect.maxY)

            guard let image = ScreenCaptureService.capture(globalCocoaRect: rect, on: selection.screen) else {
                Self.log.warn("screen capture returned nil (permission revoked mid-session?)")
                RegionToast.show(L("popbar.ocr.captureFailed"), atGlobalCocoa: anchor)
                return
            }

            TextRecognizer.recognize(image) { [weak self] text in
                guard let self else { return }
                // Discard a stale completion: a newer capture superseded this one while
                // Vision was running, so it must not overwrite the clipboard/capsule.
                guard generation == self.captureGeneration else {
                    Self.log.info("discarding stale OCR result (gen \(generation) ≠ \(self.captureGeneration))")
                    return
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    Self.log.info("OCR found no text in the region")
                    RegionToast.show(L("popbar.ocr.noText"), atGlobalCocoa: anchor)
                    return
                }
                if PopBarPreferences.screenOCRAutoCopy {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(trimmed, forType: .string)
                }
                Self.log.info("OCR recognized \(trimmed.count) chars → capsule")
                self.windows.showTransient(text: trimmed, url: nil, anchor: anchor,
                                           actions: self.actionStore.actions)
            }
        }
    }
}
