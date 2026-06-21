import SwiftUI
import AppKit
import ServiceManagement

/// The General page: Launch at Login, Language, and diagnostics (reveal the log
/// file). Self-contained — it reads/writes `SMAppService` and `Preferences`
/// directly, refreshing the login-item state on appear.
struct GeneralPage: View {

    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var languageCode: String? = {
        let saved = UserDefaults.standard.string(forKey: Preferences.Key.languageOverride) ?? ""
        return saved.isEmpty ? nil : saved
    }()

    private static let systemTag = "__system__"
    private static let log = FileLog("GeneralPage")

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) })) {
                    iconLabel("power", .green, L("Launch at Login"))
                }
                Picker(selection: Binding(
                    get: { languageCode ?? Self.systemTag },
                    set: { setLanguage($0 == Self.systemTag ? nil : $0) }
                )) {
                    Text(L("language.followSystem")).tag(Self.systemTag)
                    ForEach(LocalizationOverride.supportedCodes, id: \.self) { code in
                        Text(LocalizationOverride.nativeName(for: code)).tag(code)
                    }
                } label: {
                    iconLabel("globe", .cyan, L("Language"))
                }
            }

            Section {
                LabeledContent {
                    Button(L("diagnostics.revealLog")) {
                        NSWorkspace.shared.activateFileViewerSelecting([FileLog.url])
                    }
                } label: {
                    iconLabel("doc.text", Color(nsColor: .systemGray), L("diagnostics.log.title"))
                }
                Text(L("diagnostics.log.subtitle"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(L("Diagnostics"))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("General"))
        .onAppear {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            Self.log.error("Failed to toggle launch at login: \(error)")
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    private func setLanguage(_ code: String?) {
        languageCode = code
        Preferences.setLanguageOverride(code)
    }
}
