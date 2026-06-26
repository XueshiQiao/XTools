import SwiftUI
import AppKit

/// The PopBar settings page: enable the popup, grant Accessibility, preview the
/// capsule, and see which actions it offers.
struct PopBarView: View {

    @ObservedObject private var store: PopBarStore

    /// Poll the Accessibility grant so the UI reflects changes made in System
    /// Settings without a relaunch.
    private let trustPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init(store: PopBarStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { store.isEnabled }, set: { store.setEnabled($0) })
    }

    var body: some View {
        Form {
            statusSection
            if !store.isTrusted {
                permissionSection
            }
            actionsSection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle(L("tool.popbar.title"))
        .onAppear { store.refreshTrust() }
        .onReceive(trustPoll) { _ in store.refreshTrust() }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            Toggle(isOn: enabledBinding) {
                featureLabel("text.bubble.fill", .indigo,
                             L("popbar.enable.title"), L("popbar.enable.subtitle"))
            }
            LabeledContent {
                HStack(spacing: 6) {
                    StatusDot(active: running)
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(running ? .green : .orange)
                }
            } label: {
                iconLabel("dot.radiowaves.left.and.right", running ? .green : .gray, L("popbar.status.title"))
            }
        }
    }

    private var running: Bool { store.isEnabled && store.isTrusted }

    private var statusText: String {
        if !store.isTrusted { return L("popbar.status.needsPermission") }
        return store.isEnabled ? L("popbar.status.on") : L("popbar.status.off")
    }

    // MARK: - Permission

    private var permissionSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("popbar.perm.title")).fontWeight(.medium)
                    Text(L("popbar.perm.body"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button(L("popbar.perm.grant")) { store.requestPermission() }
                Button(L("popbar.perm.open")) { store.openAccessibilitySettings() }
                    .buttonStyle(.borderless)
            }
        } header: {
            Text(L("popbar.perm.header"))
        }
    }

    // MARK: - Actions preview

    private var actionsSection: some View {
        Section {
            ForEach(store.actions) { action in
                HStack(spacing: 10) {
                    IconTile(symbol: action.symbol, color: .indigo)
                    Text(action.title)
                    Spacer()
                    if case .copy = action.kind {
                        Text(L("popbar.tag.real")).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                    } else {
                        Text(L("popbar.tag.fake")).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }
            Button {
                store.showPreview()
            } label: {
                Label(L("popbar.preview.button"), systemImage: "eye")
            }
        } header: {
            Text(L("popbar.actions.header"))
        } footer: {
            Text(L("popbar.actions.footer")).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            Text(L("popbar.about.body"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
