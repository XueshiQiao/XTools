import Foundation
import IOKit
import IOKit.hid

enum ROGError: Error {
    case notFound
    case openFailed(IOReturn)
    case writeFailed(IOReturn)
    case timedOut(ROGCommand)
    case rejected(ROGCommand)
    case malformedReply(ROGCommand)
    case invalidProfile(Int)

    /// User-facing, localized. `Error.localizedDescription` on a bare Swift enum
    /// produces an opaque "The operation couldn’t be completed", which is exactly
    /// the kind of message that makes a failure impossible to act on.
    var message: String {
        switch self {
        case .notFound:
            return L("rog.error.notFound")
        case .openFailed(let status):
            return String(format: L("rog.error.openFailed"), String(format: "0x%08X", UInt32(bitPattern: status)))
        case .writeFailed(let status):
            return String(format: L("rog.error.writeFailed"), String(format: "0x%08X", UInt32(bitPattern: status)))
        case .timedOut(let command):
            return String(format: L("rog.error.timedOut"), command.hexDescription)
        case .rejected(let command):
            return String(format: L("rog.error.rejected"), command.hexDescription)
        case .malformedReply(let command):
            return String(format: L("rog.error.malformedReply"), command.hexDescription)
        case .invalidProfile(let number):
            return String(format: L("rog.error.invalidProfile"), number)
        }
    }
}

/// A live connection to one ASUS vendor-control HID collection.
///
/// The collection is serviced by its own run loop on a dedicated thread, so
/// waiting for a reply never blocks the caller (in the app, the main thread).
/// Requests are serialised — one outstanding command at a time, which is all
/// this protocol needs and keeps reply-pairing unambiguous.
final class ROGHIDDevice {

    /// ASUSTeK.
    static let vendorID = 0x0B05
    /// The vendor-defined control collection every ROG peripheral exposes.
    static let controlUsagePage = 0xFF00
    static let controlUsage = 1

    /// A reply of `FF AA` is the keyboard refusing the command.
    private static let rejectionPrefix: [UInt8] = [0xFF, 0xAA]

    private static let log = FileLog("ROGHIDDevice")

    let productID: Int
    let reportSize: Int

    private let device: IOHIDDevice
    private var inputBuffer: [UInt8]

    private var thread: Thread?
    private let runLoopReady = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var stopping = false
    private var isOpen = false

    // The single outstanding request, guarded by `stateLock`.
    private var expectedHeader: [UInt8]?
    private var reply: [UInt8]?
    private var replyReady: DispatchSemaphore?

    private init(device: IOHIDDevice, productID: Int, reportSize: Int) {
        self.device = device
        self.productID = productID
        self.reportSize = reportSize
        self.inputBuffer = [UInt8](repeating: 0, count: max(reportSize, 64))
    }

    deinit { close() }

    // MARK: - Discovery

    /// Every matching ASUS control collection currently attached. Pass nil to
    /// take whatever is there.
    static func discover(productIDs: Set<Int>? = nil) -> [ROGHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, [[
            kIOHIDVendorIDKey: vendorID,
            kIOHIDPrimaryUsagePageKey: controlUsagePage,
            kIOHIDPrimaryUsageKey: controlUsage,
        ]] as CFArray)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let found = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }

        var seen = Set<Int>()
        var result: [ROGHIDDevice] = []
        for device in found {
            let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
            if let productIDs, !productIDs.contains(pid) { continue }
            // macOS surfaces the same collection more than once; one handle is enough.
            guard seen.insert(pid).inserted else { continue }
            let size = (IOHIDDeviceGetProperty(device, kIOHIDMaxOutputReportSizeKey as CFString) as? Int) ?? 64
            result.append(ROGHIDDevice(device: device, productID: pid, reportSize: size))
        }
        return result
    }

    // MARK: - Lifecycle

    func open() throws {
        stateLock.lock()
        let alreadyOpen = isOpen
        stateLock.unlock()
        guard !alreadyOpen else { return }

        let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else { throw ROGError.openFailed(status) }

        let context = Unmanaged.passUnretained(self).toOpaque()
        inputBuffer.withUnsafeMutableBufferPointer { buffer in
            IOHIDDeviceRegisterInputReportCallback(
                device, buffer.baseAddress!, buffer.count,
                { context, _, _, _, _, report, length in
                    guard let context else { return }
                    Unmanaged<ROGHIDDevice>.fromOpaque(context)
                        .takeUnretainedValue()
                        .receive(report: report, length: length)
                },
                context)
        }

        stateLock.lock(); isOpen = true; stopping = false; stateLock.unlock()

        let thread = Thread { [weak self] in self?.runLoopMain() }
        thread.name = "rog-hid"
        thread.stackSize = 256 * 1024
        thread.start()
        self.thread = thread
        runLoopReady.wait()
    }

    func close() {
        stateLock.lock()
        let wasOpen = isOpen
        stopping = true
        isOpen = false
        // Never leave a caller blocked on a reply that can no longer arrive.
        replyReady?.signal()
        replyReady = nil
        expectedHeader = nil
        stateLock.unlock()
        guard wasOpen else { return }
        thread = nil
    }

    private func runLoopMain() {
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        runLoopReady.signal()
        while true {
            stateLock.lock(); let done = stopping; stateLock.unlock()
            if done { break }
            CFRunLoopRunInMode(.defaultMode, 0.1, false)
        }
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: - Traffic

    /// Fire and forget, for commands the keyboard acts on without answering.
    func send(_ command: ROGCommand) throws {
        let frame = command.frame(size: reportSize)
        let status = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, frame, frame.count)
        guard status == kIOReturnSuccess else { throw ROGError.writeFailed(status) }
    }

    /// Sends `command` and waits for the reply whose first four bytes echo it.
    ///
    /// Non-matching reports are discarded rather than mistaken for this reply.
    /// Without that check, the answer to the *previous* command reads as this
    /// one's result — observed in practice as a profile query returning the
    /// wrong profile number, which would make the tool switch to the wrong one.
    func request(_ command: ROGCommand, timeout: TimeInterval = 2.0) throws -> [UInt8] {
        let ready = DispatchSemaphore(value: 0)
        stateLock.lock()
        expectedHeader = command.header
        reply = nil
        replyReady = ready
        stateLock.unlock()

        defer {
            stateLock.lock()
            expectedHeader = nil
            replyReady = nil
            stateLock.unlock()
        }

        try send(command)

        guard ready.wait(timeout: .now() + timeout) == .success else {
            throw ROGError.timedOut(command)
        }
        stateLock.lock(); let received = reply; stateLock.unlock()
        guard let received else { throw ROGError.timedOut(command) }
        if received.count >= 2, Array(received.prefix(2)) == Self.rejectionPrefix {
            throw ROGError.rejected(command)
        }
        return received
    }

    private func receive(report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        let bytes = Array(UnsafeBufferPointer(start: report, count: min(Int(length), inputBuffer.count)))
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let expected = expectedHeader, let ready = replyReady else { return }
        let isRejection = bytes.count >= 2 && Array(bytes.prefix(2)) == Self.rejectionPrefix
        let isMatch = bytes.count >= expected.count && Array(bytes.prefix(expected.count)) == expected
        guard isMatch || isRejection else { return }   // an answer to something else
        reply = bytes
        expectedHeader = nil
        replyReady = nil
        ready.signal()
    }
}

// MARK: - Keyboard-level operations

extension ROGHIDDevice {

    func readLink() throws -> ROGLink {
        let reply = try request(.connectionType)
        guard reply.count >= 5, let link = ROGLink(rawValue: reply[4]) else {
            throw ROGError.malformedReply(.connectionType)
        }
        return link
    }

    func readDeviceInfo(link: ROGLink) throws -> ROGDeviceInfo {
        let reply = try request(.deviceInfo)
        guard let info = ROGDeviceInfo(reply: reply, link: link) else {
            throw ROGError.malformedReply(.deviceInfo)
        }
        return info
    }

    /// Link plus device info in one go — what every caller actually wants.
    func readState() throws -> (link: ROGLink, info: ROGDeviceInfo) {
        let link = try readLink()
        return (link, try readDeviceInfo(link: link))
    }

    /// Switches the profile and reads back what actually took, so no caller has
    /// to assume the write landed. Refuses out-of-range numbers rather than
    /// letting the firmware reinterpret them (0 selects the last profile).
    @discardableResult
    func changeProfile(to number: Int, link: ROGLink, profileCount: Int) throws -> ROGDeviceInfo {
        guard ROGProfile.isValid(number, count: profileCount) else {
            throw ROGError.invalidProfile(number)
        }
        try send(.changeProfile(number))
        // The keyboard reloads its key map before it answers accurately.
        Thread.sleep(forTimeInterval: 0.25)
        let info = try readDeviceInfo(link: link)
        if info.currentProfile != number {
            Self.log.error("profile switch did not stick: asked \(number), got \(info.currentProfile)")
        }
        return info
    }
}
