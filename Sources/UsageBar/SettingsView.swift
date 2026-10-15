import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var launchAtLogin: LaunchAtLoginController

    var body: some View {
        Form {
            Section("Monthly prices") {
                OptionalDoubleField(title: "Claude", value: $store.settings.priceClaude)
                OptionalDoubleField(title: "ChatGPT", value: $store.settings.priceChatGPT)
                OptionalDoubleField(title: "OpenCode", value: $store.settings.priceOpenCode)
                OptionalDoubleField(title: "Grok Bot", value: $store.settings.priceGrokBot)
                OptionalDoubleField(title: "VPS", value: $store.settings.priceVPS)
                OptionalDoubleField(title: "Other", value: $store.settings.priceOther)
            }

            Section("VPS billing") {
                OptionalDateField(title: "Due date", value: $store.settings.vpsDueDate)
                Picker("Period", selection: $store.settings.vpsBillingPeriod) {
                    ForEach(BillingPeriod.allCases) { period in
                        Text(period.label).tag(period)
                    }
                }
                Text("Leave VPS price/due blank to use OVH values.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Manual values") {
                OptionalDoubleField(title: "Grok % left", value: $store.settings.manualGrokPercentLeft)
                OptionalDoubleField(title: "Claude 5h % left", value: $store.settings.manualClaude5hLeft)
                OptionalDoubleField(title: "Claude week % left", value: $store.settings.manualClaudeWeekLeft)
                OptionalDoubleField(title: "DeepSeek balance", value: $store.settings.manualDeepseekBalance)
            }

            Section("DeepSeek API") {
                TextField("Endpoint URL", text: optionalStringBinding(\.deepseekEndpointURL))
                SecureField("Token", text: optionalStringBinding(\.deepseekToken))
            }

            Section("OpenCode") {
                TextField("Console URL (your …/console/org_…/go page)", text: stringBinding(\.opencodeConsoleURL))
                OptionalDoubleField(title: "Monthly cap", value: $store.settings.opencodeMonthlyCap)
                Toggle("Manual cap override", isOn: $store.settings.opencodeOverride)
                Text("Entered prices always win. Live caps win unless overridden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Console refresh interval")
                    Spacer()
                    Stepper(
                        "\(store.settings.clampedOpenCodeRefreshMinutes) min",
                        value: $store.settings.opencodeRefreshMinutes,
                        in: 15...240,
                        step: 15
                    )
                }
            }

            Section("Currency") {
                Picker("Display currency", selection: $store.settings.displayCurrency) {
                    ForEach(Settings.supportedCurrencies, id: \.self) { code in
                        Text(code).tag(code)
                    }
                }
                Picker("Price currency", selection: $store.settings.priceCurrency) {
                    ForEach(Settings.supportedCurrencies, id: \.self) { code in
                        Text(code).tag(code)
                    }
                }
                HStack {
                    Text("USD → EUR rate")
                    Spacer()
                    TextField("auto", text: fxOverrideBinding("USD->EUR"))
                        .frame(width: 150)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("GBP → EUR rate")
                    Spacer()
                    TextField("auto", text: fxOverrideBinding("GBP->EUR"))
                        .frame(width: 150)
                        .multilineTextAlignment(.trailing)
                }
                Text("Blank = auto (ECB rates, cached 24 h). Entered prices start in the price currency.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Refresh") {
                HStack {
                    Text("Interval")
                    Spacer()
                    Stepper(
                        "\(store.settings.clampedRefreshMinutes) min",
                        value: $store.settings.refreshIntervalMinutes,
                        in: 5...30
                    )
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $store.settings.launchAtLogin)
                if !launchAtLogin.statusText.isEmpty {
                    Text(launchAtLogin.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Menu bar") {
                Picker("Display", selection: menuBarModeBinding) {
                    ForEach(MenuBarMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Toggle("Show labels", isOn: menuBarLabelledBinding)
                Toggle("Show logos", isOn: $store.settings.menuBarShowLogos)

                ForEach(orderedMenuBarItems, id: \.self) { item in
                    HStack {
                        Toggle("", isOn: menuBarItemBinding(item))
                            .labelsHidden()
                        Text(item.title)
                        Spacer()
                        Button { moveMenuBarItem(item, by: -1) } label: {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!canMoveMenuBarItem(item, by: -1))
                        Button { moveMenuBarItem(item, by: 1) } label: {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!canMoveMenuBarItem(item, by: 1))
                    }
                }
            }
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .formStyle(.grouped)
        .frame(width: 460, height: 780)
        .onAppear { launchAtLogin.refresh() }
    }

    /// Selected items first, in order, then the remaining item types. Uses the
    /// effective list so the §16 defaults are shown until the user customises.
    private var orderedMenuBarItems: [MenuBarItem] {
        let selected = store.settings.effectiveMenuBarItems
        let rest = MenuBarItem.allCases.filter { !selected.contains($0) }
        return selected + rest
    }

    /// Menu bar edits mark the settings as customised (SPEC §16), freezing the
    /// defaults so the user's choice sticks.
    private var menuBarModeBinding: Binding<MenuBarMode> {
        Binding(
            get: { store.settings.effectiveMenuBarMode },
            set: { newValue in
                var settings = store.settings
                settings.customizeMenuBar()
                settings.menuBarMode = newValue
                store.settings = settings
            }
        )
    }

    private var menuBarLabelledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.effectiveMenuBarLabelled },
            set: { newValue in
                var settings = store.settings
                settings.customizeMenuBar()
                settings.menuBarLabelled = newValue
                store.settings = settings
            }
        )
    }

    /// Checkbox binding: toggling adds/removes the item from the ordered list.
    private func menuBarItemBinding(_ item: MenuBarItem) -> Binding<Bool> {
        Binding(
            get: { store.settings.effectiveMenuBarItems.contains(item) },
            set: { isOn in
                var items = store.settings.effectiveMenuBarItems
                if isOn {
                    if !items.contains(item) { items.append(item) }
                } else {
                    items.removeAll { $0 == item }
                }
                var settings = store.settings
                settings.customizeMenuBar()
                settings.menuBarItems = items
                store.settings = settings
            }
        )
    }

    private func canMoveMenuBarItem(_ item: MenuBarItem, by delta: Int) -> Bool {
        let items = store.settings.effectiveMenuBarItems
        guard let index = items.firstIndex(of: item) else { return false }
        let target = index + delta
        return target >= 0 && target < items.count
    }

    private func moveMenuBarItem(_ item: MenuBarItem, by delta: Int) {
        var items = store.settings.effectiveMenuBarItems
        guard let index = items.firstIndex(of: item) else { return }
        let target = index + delta
        guard target >= 0, target < items.count else { return }
        items.swapAt(index, target)
        var settings = store.settings
        settings.customizeMenuBar()
        settings.menuBarItems = items
        store.settings = settings
    }

    /// Two-way binding between an optional String field and a TextField.
    private func optionalStringBinding(_ keyPath: WritableKeyPath<Settings, String?>) -> Binding<String> {
        Binding(
            get: { store.settings[keyPath: keyPath] ?? "" },
            set: { store.settings[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    /// Two-way binding for a non-optional String field.
    private func stringBinding(_ keyPath: WritableKeyPath<Settings, String>) -> Binding<String> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { store.settings[keyPath: keyPath] = $0 }
        )
    }

    /// Blank = auto; a positive number is stored as a manual override.
    private func fxOverrideBinding(_ key: String) -> Binding<String> {
        Binding(
            get: {
                guard let value = store.settings.fxOverrides[key] else { return "" }
                return value == value.rounded() ? String(format: "%.0f", value) : String(format: "%g", value)
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    store.settings.fxOverrides.removeValue(forKey: key)
                } else if let value = Double(trimmed), value > 0, value.isFinite {
                    store.settings.fxOverrides[key] = value
                }
            }
        )
    }
}

/// Text field editing an `Optional<Double>` with an "e.g. 20" placeholder.
/// Leaving the field empty stores `nil`; invalid input is ignored.
struct OptionalDoubleField: View {
    let title: String
    @Binding var value: Double?
    var placeholder: String = "e.g. 20"

    @State private var text: String = ""

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(placeholder, text: $text)
                .frame(width: 150)
                .multilineTextAlignment(.trailing)
                .onAppear { text = value.map { format($0) } ?? "" }
                .onChange(of: text) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty {
                        value = nil
                    } else if let parsed = Double(trimmed), parsed.isFinite {
                        value = parsed
                    }
                }
        }
    }

    private func format(_ d: Double) -> String {
        d == d.rounded() ? String(format: "%.0f", d) : String(format: "%g", d)
    }
}

/// Date picker with an explicit "set / not set" toggle for an optional date.
struct OptionalDateField: View {
    let title: String
    @Binding var value: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(
                title,
                isOn: Binding(
                    get: { value != nil },
                    set: { isOn in value = isOn ? (value ?? Date()) : nil }
                )
            )
            if value != nil {
                DatePicker(
                    "Due date",
                    selection: Binding(
                        get: { value ?? Date() },
                        set: { value = $0 }
                    ),
                    displayedComponents: .date
                )
                .labelsHidden()
            }
        }
    }
}
