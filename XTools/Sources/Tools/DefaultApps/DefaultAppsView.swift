import SwiftUI
import AppKit

/// The Default Apps page: a curated list of common file types and URL schemes,
/// each showing its current default handler (icon + name) with a menu to pick a
/// different installed app. Changes are user-domain (no admin password).
struct DefaultAppsView: View {

    @ObservedObject private var store: DefaultAppsStore

    init(store: DefaultAppsStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        Form {
            if let message = store.actionMessage {
                Section { messageBanner(message) }
            }
            fileTypesSection
            urlSchemesSection
        }
        .formStyle(.grouped)
        .navigationTitle(L("tool.defaultapps.title"))
        .toolbar {
            ToolbarItem {
                Button { store.refresh() } label: {
                    Label(L("launch.refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(store.isScanning)
            }
        }
        .onAppear { store.refresh() }
    }

    // MARK: - File types

    private var fileTypesSection: some View {
        Section {
            if store.fileTypes.isEmpty {
                Text(store.isScanning ? L("launch.scanning") : L("defaultapps.empty"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(store.fileTypes) { itemRow($0) }
            }
        } header: {
            Text(L("defaultapps.section.fileTypes"))
        } footer: {
            Text(L("defaultapps.fileTypes.footer")).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - URL schemes

    private var urlSchemesSection: some View {
        Section {
            if store.urlSchemes.isEmpty {
                Text(store.isScanning ? L("launch.scanning") : L("defaultapps.empty"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(store.urlSchemes) { itemRow($0) }
            }
        } header: {
            Text(L("defaultapps.section.urlSchemes"))
        } footer: {
            Text(L("defaultapps.urlSchemes.footer")).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Row

    private func itemRow(_ item: HandledItem) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: item.symbol, color: .indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).fontWeight(.medium)
                Text(item.identifier)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            handlerControl(item)
        }
        .padding(.vertical, 2)
    }

    /// The current-handler display + change control. A menu when there's a choice;
    /// a static label when there's only one (or zero) installed handler.
    @ViewBuilder
    private func handlerControl(_ item: HandledItem) -> some View {
        if item.hasChoice {
            Menu {
                ForEach(item.candidates) { app in
                    Button {
                        store.setHandler(app, for: item)
                    } label: {
                        if app.bundleID == item.current?.bundleID {
                            Label(app.name, systemImage: "checkmark")
                        } else {
                            Text(app.name)
                        }
                    }
                }
            } label: {
                handlerLabel(item.current)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } else {
            handlerLabel(item.current)
        }
    }

    /// Icon + name of an app handler (or a muted "None" when nothing is set).
    private func handlerLabel(_ app: HandlerApp?) -> some View {
        HStack(spacing: 6) {
            if let app {
                appIcon(app).resizable().frame(width: 18, height: 18)
                Text(app.name).lineLimit(1).truncationMode(.middle)
            } else {
                Image(systemName: "questionmark.app.dashed").foregroundStyle(.secondary)
                Text(L("defaultapps.none")).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
    }

    private func appIcon(_ app: HandlerApp) -> Image {
        if let icon = app.icon { return Image(nsImage: icon) }
        return Image(systemName: "app.dashed")
    }

    // MARK: - Banner

    private func messageBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { store.actionMessage = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
    }
}
