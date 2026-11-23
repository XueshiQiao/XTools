import SwiftUI
import Combine

/// Why a profile switch was requested — drives what the notification says.
enum ROGSwitchReason {
    /// The keyboard came back to the Mac on its own and the tool acted without
    /// being asked.
    case autoReturn
    /// XTools started with the keyboard already on the Mac but still on the
    /// Windows profile — it came back while XTools was not running to catch it.
    case startupCorrection
    case mac
    case windows
    case manual

    var localizedRole: String {
        switch self {
        case .autoReturn, .startupCorrection, .mac: return L("rog.role.mac")
        case .windows:          return L("rog.role.windows")
        case .manual:           return L("rog.role.manual")
        }
    }

    /// Nobody clicked anything, so the notification is the only evidence the tool
    /// did its job — including when its job turned out to be nothing.
    var isAutomatic: Bool { self == .autoReturn || self == .startupCorrection }

    /// Notification text (a format taking role and profile name) for a switch
    /// that landed, and for one that turned out to be unnecessary.
    var switchedKey: String {
        switch self {
        case .autoReturn:        return "rog.notify.autoSwitched"
        case .startupCorrection: return "rog.notify.startupSwitched"
        default:                 return "rog.notify.switched"
        }
    }
    var unchangedKey: String {
        isAutomatic ? "rog.notify.autoUnchanged" : "rog.notify.unchanged"
    }
}

/// UI model and coordinator for the ROG Keyboard tool.
///
/// All HID traffic runs on a private serial queue; everything published lands on
/// main. The device handle is opened per operation rather than held open — the
/// keyboard disappears and reappears as the user flips its mode switch, so a
/// long-lived handle would spend most of its life stale.
final class ROGKeyboardStore: ObservableObject {

    private static let log = FileLog("ROGKeyboard")

    private enum Key {
        static let macProfile = "rogKeyboard.macProfile"
        static let windowsProfile = "rogKeyboard.windowsProfile"
        static let autoSwitch = "rogKeyboard.autoSwitchOnAttach"
        static let sound = "rogKeyboard.notificationSound"
    }

    // MARK: - Observed state

    @Published private(set) var isConnected = false
    @Published private(set) var link: ROGLink?
    @Published private(set) var info: ROGDeviceInfo?
    @Published private(set) var isBusy = false
    /// Last thing that happened, shown as a banner. Cleared on the next action.
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var notificationsAuthorized = true

    // MARK: - Settings

    @Published var macProfile: Int {
        didSet { UserDefaults.standard.set(macProfile, forKey: Key.macProfile) }
    }
    @Published var windowsProfile: Int {
        didSet { UserDefaults.standard.set(windowsProfile, forKey: Key.windowsProfile) }
    }
    @Published var autoSwitchEnabled: Bool {
        didSet { UserDefaults.standard.set(autoSwitchEnabled, forKey: Key.autoSwitch) }
    }
    @Published var soundEnabled: Bool {
        didSet {
            UserDefaults.standard.set(soundEnabled, forKey: Key.sound)
            notifier.playSound = soundEnabled
        }
    }

    /// How many profiles the keyboard reports. Falls back to a sane range so the
    /// settings pickers still work while the keyboard is on the other computer.
    var profileCount: Int { max(info?.profileCount ?? 6, ROGProfile.first) }

    /// Selectable slots in the order ASUS's configurator lists them.
    var orderedProfiles: [Int] { ROGProfileNaming.orderedSlots(count: profileCount) }

    /// The name the user sees. Never the wire number.
    func profileLabel(_ wire: Int) -> String {
        ROGProfileNaming.label(wire: wire, count: profileCount)
    }

    // MARK: - Collaborators

    private let monitor = ROGKeyboardMonitor()
    private let notifier = ROGNotifier()
    private let queue = DispatchQueue(label: "me.xueshi.xtools.rogkeyboard", qos: .userInitiated)

    init() {
        let defaults = UserDefaults.standard
        let savedMac = defaults.integer(forKey: Key.macProfile)
        let savedWindows = defaults.integer(forKey: Key.windowsProfile)
        // `integer(forKey:)` returns 0 for an absent key, and 0 is exactly the
        // value the firmware misinterprets — so an unset preference must never
        // reach the wire.
        macProfile = savedMac >= ROGProfile.first ? savedMac : 1
        windowsProfile = savedWindows >= ROGProfile.first ? savedWindows : 2
        autoSwitchEnabled = defaults.object(forKey: Key.autoSwitch) as? Bool ?? true
        soundEnabled = defaults.object(forKey: Key.sound) as? Bool ?? true
        notifier.playSound = soundEnabled
    }

    // MARK: - Lifetime

    func start() {
        notifier.onAuthorizationChanged = { [weak self] authorized in
            self?.notificationsAuthorized = authorized
        }
        notifier.requestAuthorization()
        monitor.onAlreadyPresent = { [weak self] in
            guard let self else { return }
            // Present at launch is not an arrival, so a profile the user picked
            // by hand is left alone — re-asserting the Mac profile on every launch
            // would quietly undo it. The one state that is never wanted is the
            // keyboard sitting on this Mac with the Windows profile: it came back
            // while XTools was not running (quit, restarting, an old build), and
            // nothing was there to switch it. Correct exactly that.
            guard self.autoSwitchEnabled, self.macProfile != self.windowsProfile else {
                self.refresh()
                return
            }
            self.applyProfile(self.macProfile, reason: .startupCorrection,
                              onlyIfCurrentIs: self.windowsProfile)
        }
        monitor.onAttached = { [weak self] in
            guard let self else { return }
            self.refresh()
            guard self.autoSwitchEnabled else {
                Self.log.info("keyboard came back but auto-switch is off — leaving it alone")
                return
            }
            Self.log.info("keyboard came back — restoring the Mac profile")
            self.applyProfile(self.macProfile, reason: .autoReturn)
        }
        monitor.onDetached = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isConnected = false
                self.link = nil
                self.statusMessage = L("rog.status.gone")
                self.errorMessage = nil
            }
        }
        monitor.start()
        refresh()
    }

    func stop() {
        monitor.stop()
    }

    // MARK: - Actions

    func refresh() {
        notifier.refreshAuthorization()
        run { device in
            let state = try device.readState()
            return { [weak self] in
                guard let self else { return }
                self.isConnected = true
                self.link = state.link
                self.info = state.info
                self.errorMessage = nil
            }
        }
    }

    func switchToMac()     { applyProfile(macProfile, reason: .mac) }
    func switchToWindows() { applyProfile(windowsProfile, reason: .windows) }
    func switchTo(_ number: Int) { applyProfile(number, reason: .manual) }

    /// Switches the keyboard and announces it. The announcement is not optional —
    /// see `ROGNotifier`.
    /// - Parameter onlyIfCurrentIs: when set, switch only if the keyboard is on
    ///   this profile right now; otherwise just record the state, silently.
    private func applyProfile(_ number: Int, reason: ROGSwitchReason, onlyIfCurrentIs required: Int? = nil) {
        run { [weak self] device in
            let state = try device.readState()
            if let required, state.info.currentProfile != required {
                Self.log.info("\(reason) — on \(ROGProfileNaming.label(wire: state.info.currentProfile, count: state.info.profileCount)), not the Windows profile — leaving it alone")
                return { [weak self] in
                    guard let self else { return }
                    self.isConnected = true
                    self.link = state.link
                    self.info = state.info
                    self.errorMessage = nil
                }
            }
            guard ROGProfile.isValid(number, count: state.info.profileCount) else {
                throw ROGError.invalidProfile(number)
            }
            let count = state.info.profileCount
            let wanted = ROGProfileNaming.label(wire: number, count: count)

            if state.info.currentProfile == number {
                // Nothing to change — but say so anyway. Staying silent here is
                // indistinguishable from the tool being broken, which is exactly
                // how it read the first time the keyboard came back already on
                // the right profile.
                Self.log.info("\(reason) — already on \(wanted), nothing to change")
                self?.notifier.post(
                    title: L("rog.notify.title"),
                    body: String(format: L(reason.unchangedKey),
                                 reason.localizedRole, wanted))
                return { [weak self] in
                    self?.info = state.info
                    self?.link = state.link
                    self?.isConnected = true
                    self?.statusMessage = String(format: L("rog.status.alreadyOn"), reason.localizedRole, wanted)
                }
            }
            let after = try device.changeProfile(to: number, link: state.link, profileCount: count)
            let landed = after.currentProfile == number
            let actual = ROGProfileNaming.label(wire: after.currentProfile, count: count)
            Self.log.info("\(reason) — \(ROGProfileNaming.label(wire: state.info.currentProfile, count: count)) → \(actual)\(landed ? "" : " (asked for \(wanted))")")
            self?.notifier.post(
                title: L("rog.notify.title"),
                body: landed
                    ? String(format: L(reason.switchedKey),
                             reason.localizedRole, wanted)
                    : String(format: L("rog.notify.failed"), wanted, actual))
            return { [weak self] in
                guard let self else { return }
                self.info = after
                self.link = state.link
                self.isConnected = true
                self.statusMessage = landed
                    ? String(format: L("rog.status.switched"), reason.localizedRole, wanted)
                    : String(format: L("rog.status.didNotStick"), wanted, actual)
                self.errorMessage = landed ? nil : String(format: L("rog.status.didNotStick"), wanted, actual)
            }
        }
    }

    // MARK: - Plumbing

    /// Opens the keyboard, runs `work` off-main, and applies the returned closure
    /// on main. Every failure lands in `errorMessage` rather than vanishing.
    private func run(_ work: @escaping (ROGHIDDevice) throws -> (() -> Void)) {
        DispatchQueue.main.async { self.isBusy = true; self.statusMessage = nil }
        queue.async { [weak self] in
            guard let self else { return }
            var device: ROGHIDDevice?
            do {
                guard let found = ROGHIDDevice.discover(productIDs: ROGModel.allProductIDs).first else {
                    throw ROGError.notFound
                }
                device = found
                try found.open()
                let apply = try work(found)
                found.close()
                DispatchQueue.main.async { self.isBusy = false; apply() }
            } catch let error as ROGError {
                device?.close()
                Self.log.error(error.message)
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.errorMessage = error.message
                    if case .notFound = error { self.isConnected = false; self.link = nil }
                }
            } catch {
                device?.close()
                Self.log.error("unexpected: \(error)")
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
