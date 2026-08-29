import SwiftUI

/// The ROG Keyboard page: which on-board profile stands for "I'm on the Mac"
/// and which for "I'm on the PC", plus the switch that puts them into effect.
struct ROGKeyboardView: View {

    @ObservedObject private var store: ROGKeyboardStore

    init(store: ROGKeyboardStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        Form {
            if let error = store.errorMessage {
                Section { banner(error, symbol: "exclamationmark.triangle.fill", tint: .orange) }
            } else if let message = store.statusMessage {
                Section { banner(message, symbol: "checkmark.circle.fill", tint: .green) }
            }
            statusSection
            profilesSection
            automationSection
        }
        .formStyle(.grouped)
        .navigationTitle(L("tool.rogkeyboard.title"))
        .toolbar {
            ToolbarItem {
                Button { store.refresh() } label: {
                    Label(L("launch.refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(store.isBusy)
            }
        }
        .onAppear { store.refresh() }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 6) {
                    StatusDot(active: store.isConnected)
                    Text(store.isConnected ? L("rog.status.connected") : L("rog.status.disconnected"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(store.isConnected ? .green : .orange)
                }
            } label: {
                iconLabel("keyboard", .indigo, ROGModel.falcata.displayName)
            }

            if store.isConnected, let info = store.info {
                LabeledContent {
                    Text(store.profileLabel(info.currentProfile))
                        .font(.system(size: 11, weight: .semibold))
                } label: {
                    Text(L("rog.status.currentProfile"))
                }
                LabeledContent {
                    Text(store.link?.localizedName ?? "—").font(.system(size: 11))
                } label: {
                    Text(L("rog.status.link"))
                }
                LabeledContent {
                    Text(info.firmwareVersion).font(.system(size: 11, design: .monospaced))
                } label: {
                    Text(L("rog.status.firmware"))
                }
            } else {
                Text(L("rog.status.disconnected.hint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(L("rog.section.status"))
        }
    }

    // MARK: - Profiles

    private var profilesSection: some View {
        Section {
            Picker(selection: $store.macProfile) {
                ForEach(store.orderedProfiles, id: \.self) { slot in
                    Text(store.profileLabel(slot)).tag(slot)
                }
            } label: {
                iconLabel("apple.logo", .blue, L("rog.profile.mac"))
            }

            Picker(selection: $store.windowsProfile) {
                ForEach(store.orderedProfiles, id: \.self) { slot in
                    Text(store.profileLabel(slot)).tag(slot)
                }
            } label: {
                iconLabel("pc", .teal, L("rog.profile.windows"))
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L("rog.action.switchToMac")) { store.switchToMac() }
                    .disabled(store.isBusy || !store.isConnected)
                Button(L("rog.action.switchToWindows")) { store.switchToWindows() }
                    .disabled(store.isBusy || !store.isConnected)
            }
        } header: {
            Text(L("rog.section.profiles"))
        } footer: {
            Text(L("rog.section.profiles.footer"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Automation

    private var automationSection: some View {
        Section {
            Toggle(isOn: $store.autoSwitchEnabled) {
                featureLabel("arrow.uturn.left.circle.fill", .green,
                             L("rog.auto.title"), L("rog.auto.subtitle"))
            }
            Toggle(isOn: $store.soundEnabled) {
                iconLabel("bell.badge.fill", .pink, L("rog.sound.title"))
            }
            if !store.notificationsAuthorized {
                Text(L("rog.notify.denied"))
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(L("rog.section.automation"))
        } footer: {
            Text(L("rog.section.automation.footer"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Bits

    private func banner(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
