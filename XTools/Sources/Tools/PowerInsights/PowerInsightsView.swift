import SwiftUI

/// The Power & Battery Insights page: battery health, the active pmset power/
/// sleep settings, and recent wake/sleep events — all read-only.
struct PowerInsightsView: View {

    @ObservedObject private var store: PowerInsightsStore

    init(store: PowerInsightsStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        Form {
            if store.battery.isPresent {
                batterySection
            } else {
                noBatterySection
            }
            settingsSection
            wakeSection
        }
        .formStyle(.grouped)
        .navigationTitle(L("tool.power.title"))
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

    // MARK: - Battery

    private var batterySection: some View {
        Section {
            // Current charge + charging/AC state.
            if let power = store.battery.power {
                LabeledContent {
                    Text(chargeText(power))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(power.source == .ac ? .green : .primary)
                } label: {
                    iconLabel(chargeSymbol(power), .green, L("power.battery.charge"))
                }

                LabeledContent {
                    Text(powerStateText(power)).foregroundStyle(.secondary)
                } label: {
                    iconLabel(power.source == .ac ? "powerplug.fill" : "battery.50",
                              .blue, L("power.battery.source"))
                }

                if let minutes = power.minutesRemaining {
                    LabeledContent {
                        Text(durationText(minutes)).foregroundStyle(.secondary)
                    } label: {
                        iconLabel("clock.fill", .orange,
                                  power.isCharging ? L("power.battery.timeToFull")
                                                   : L("power.battery.timeToEmpty"))
                    }
                }
            }

            // Health.
            if let health = store.battery.maxCapacityPercent {
                LabeledContent {
                    Text("\(health)%")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(health >= 80 ? .green : .orange)
                } label: {
                    iconLabel("heart.fill", .pink, L("power.battery.health"))
                }
            }
            if let condition = store.battery.condition {
                LabeledContent {
                    Text(condition.label)
                        .foregroundStyle(condition.isHealthy ? .green : .orange)
                } label: {
                    iconLabel("checkmark.seal.fill", .teal, L("power.battery.condition"))
                }
            }
            if let cycles = store.battery.cycleCount {
                LabeledContent {
                    Text("\(cycles)").foregroundStyle(.secondary)
                } label: {
                    iconLabel("arrow.triangle.2.circlepath", .indigo, L("power.battery.cycles"))
                }
            }
            if let temp = store.battery.temperatureCelsius {
                LabeledContent {
                    Text(String(format: "%.1f °C", temp)).foregroundStyle(.secondary)
                } label: {
                    iconLabel("thermometer.medium", .red, L("power.battery.temperature"))
                }
            }
            if let max = store.battery.maxCapacity, let design = store.battery.designCapacity {
                LabeledContent {
                    Text("\(max) / \(design) mAh").foregroundStyle(.secondary)
                } label: {
                    iconLabel("bolt.fill", .yellow, L("power.battery.capacity"))
                }
            }
        } header: {
            Text(L("power.section.battery"))
        }
    }

    private var noBatterySection: some View {
        Section {
            Text(store.isScanning ? L("launch.scanning") : L("power.noBattery"))
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text(L("power.section.battery"))
        }
    }

    // MARK: - pmset settings

    private var settingsSection: some View {
        Section {
            if store.settings.isEmpty {
                Text(store.isScanning ? L("launch.scanning") : L("power.settings.empty"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(store.settings) { setting in
                    LabeledContent {
                        Text(setting.displayValue).foregroundStyle(.secondary)
                            .font(.system(.body, design: .monospaced))
                    } label: {
                        Text(setting.label)
                    }
                }
            }
        } header: {
            Text(L("power.section.settings"))
        } footer: {
            Text(L("power.settings.footer")).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Wake events

    private var wakeSection: some View {
        Section {
            if store.wakeEvents.isEmpty {
                Text(store.isScanning ? L("launch.scanning") : L("power.wake.empty"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(store.wakeEvents) { wakeRow($0) }
            }
        } header: {
            Text(L("power.section.wake"))
        } footer: {
            Text(L("power.wake.footer")).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func wakeRow(_ event: WakeEvent) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: event.symbol, color: color(for: event.kind))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kindLabel(event.kind)).fontWeight(.medium)
                    if let date = event.date {
                        Text(timeText(date)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !event.reason.isEmpty {
                    Text(event.reason)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Formatting

    private func chargeText(_ power: PowerState) -> String {
        guard let pct = power.chargePercent else { return L("power.value.unknown") }
        return "\(pct)%"
    }

    private func chargeSymbol(_ power: PowerState) -> String {
        if power.isCharging { return "battery.100.bolt" }
        switch power.chargePercent ?? 0 {
        case ..<13:  return "battery.0"
        case ..<38:  return "battery.25"
        case ..<63:  return "battery.50"
        case ..<88:  return "battery.75"
        default:     return "battery.100"
        }
    }

    private func powerStateText(_ power: PowerState) -> String {
        if power.isCharged { return L("power.state.charged") }
        if power.isCharging { return L("power.state.charging") }
        switch power.source {
        case .ac:      return L("power.state.ac")
        case .battery: return L("power.state.battery")
        case .unknown: return L("power.value.unknown")
        }
    }

    private func durationText(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h > 0 { return String(format: L("power.duration.hm"), h, m) }
        return String(format: L("power.duration.m"), m)
    }

    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func kindLabel(_ kind: WakeEvent.Kind) -> String {
        switch kind {
        case .wake:     return L("power.event.wake")
        case .sleep:    return L("power.event.sleep")
        case .darkWake: return L("power.event.darkWake")
        }
    }

    private func color(for kind: WakeEvent.Kind) -> Color {
        switch kind {
        case .wake:     return .orange
        case .sleep:    return .indigo
        case .darkWake: return .purple
        }
    }
}
