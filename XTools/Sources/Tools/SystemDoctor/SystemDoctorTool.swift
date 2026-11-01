import SwiftUI

/// System Doctor (`system-doctor`): read-only inspection tool for WindowServer CPU,
/// Mach port leak detection, full-screen high-layer overlay windows, and runaway
/// background orphan processes.
///
/// Strictly read-only by design: never terminates, signals, or restarts any process.
final class SystemDoctorTool: XToolModule {

    let id = "system-doctor"
    var title: String { L("tool.sysdoc.title") }
    let symbol = "stethoscope"
    let color = Color.mint

    private let store = SystemDoctorStore()

    func activate() {
        store.startBackgroundSchedule()
    }

    func shutdown() {
        store.stopBackgroundSchedule()
    }

    func makeRootView() -> AnyView {
        AnyView(SystemDoctorView(store: store))
    }
}
