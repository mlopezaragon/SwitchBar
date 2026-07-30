import SwiftUI
import ServiceManagement
import ClaudeSwitchCore

/// Ventana de detalle: anillos de uso por cuenta y ajustes.
struct DetailView: View {
    @Bindable var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headline

                AnthropicStatusBanner(
                    snapshot: state.anthropicStatus,
                    unavailable: state.anthropicStatusUnavailable,
                    checking: state.isCheckingAnthropicStatus,
                    compact: false,
                    openOfficialPage: state.openAnthropicStatusPage
                )

                if let notice = state.usageRefreshNotice {
                    Label(notice, systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                }

                if let unsaved = state.activeUnsaved {
                    HStack {
                        Text(
                            L10n.tr(
                                "account.unsaved.detail",
                                unsaved.emailAddress
                            )
                        )
                            .font(.callout)
                        Spacer()
                        Button(L10n.tr("account.save_account")) {
                            state.captureActive()
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.08)))
                }

                ForEach(state.profilesList) { profile in
                    accountSection(profile)
                }

                settingsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(.background)
        .onAppear { state.refreshIfStale() }
        .sheet(isPresented: $state.addAccountVisible) {
            AddAccountSheet(state: state)
        }
    }

    private var headline: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ClaudeSwitch")
                    .font(.system(size: 22, weight: .semibold))
                if let active = state.activeProfile {
                    Text(
                        L10n.tr(
                            "account.active.detail",
                            active.emailAddress
                        )
                    )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                state.beginAddAccount()
            } label: {
                Label(L10n.tr("account.add"), systemImage: "plus")
            }
        }
    }

    private func accountSection(_ profile: AccountProfile) -> some View {
        let usage = state.usageByAccount[profile.accountUuid]
        let isActive = profile.accountUuid == state.activeAccountUuid
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(profile.needsLogin ? Color.orange : (isActive ? Color.green : Color.secondary.opacity(0.4)))
                    .frame(width: 8, height: 8)
                Text(profile.emailAddress)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let plan = profile.subscriptionType {
                    Text(plan.capitalized)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if isActive {
                    Text(L10n.tr("account.active"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .fixedSize()
                } else {
                    Button(L10n.tr("account.change_to")) {
                        state.switchTo(profile.accountUuid)
                    }
                        .controlSize(.small)
                        .disabled(profile.needsLogin)
                        .fixedSize()
                }

                Menu {
                    Button(
                        L10n.tr("account.delete_profile"),
                        role: .destructive
                    ) {
                        state.removeProfile(profile.accountUuid)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
            }

            if profile.needsLogin {
                HStack(spacing: 10) {
                    Text(
                        L10n.tr("account.needs_login.explanation")
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    Spacer()
                    Button(L10n.tr("account.login_again")) {
                        state.beginReconnect(profile)
                    }
                    .controlSize(.small)
                }
            }

            HStack(spacing: 24) {
                UsageRing(label: L10n.tr("usage.five_hours"), window: usage?.fiveHour)
                UsageRing(label: L10n.tr("usage.week"), window: usage?.sevenDay)
                UsageRing(label: L10n.tr("usage.fable"), window: usage?.sevenDayOpus)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            SharedAccountControls(profile: profile, state: state)

            if let fetched = usage?.fetchedAt {
                Text(
                    L10n.tr(
                        "usage.updated",
                        ResetFormatter.since(fetched)
                    )
                )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quinary))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isActive ? Color.green.opacity(0.3) : Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("settings.title"))
                .font(.system(size: 15, weight: .semibold))

            Toggle(
                L10n.tr("auto_switch.settings_label"),
                isOn: $state.autoSwitchEnabled
            )
                .toggleStyle(.switch)

            if state.autoSwitchEnabled && state.autoSwitchPausedByManualLogin {
                Text(L10n.tr("auto_switch.paused_manual_login"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            thresholdRow(
                L10n.tr("auto_switch.threshold.five_hour"),
                value: $state.triggerThreshold
            )
            thresholdRow(
                L10n.tr("auto_switch.threshold.weekly"),
                value: $state.weeklyTriggerThreshold
            )

            Toggle(
                L10n.tr("auto_switch.use_fable"),
                isOn: $state.useFableForAutoSwitch
            )
            .toggleStyle(.switch)
            .controlSize(.small)

            if state.useFableForAutoSwitch {
                thresholdRow(
                    L10n.tr("auto_switch.threshold.fable"),
                    value: $state.fableTriggerThreshold
                )
            }

            Text(
                state.useFableForAutoSwitch
                    ? L10n.tr("auto_switch.fable.enabled_explanation")
                    : L10n.tr("auto_switch.fable.disabled_explanation")
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(L10n.tr("settings.refresh_frequency"))
                    .font(.callout)
                Spacer()
                Picker("", selection: $state.pollIntervalSeconds) {
                    Text(L10n.tr("settings.minutes", 3)).tag(180.0)
                    Text(L10n.tr("settings.minutes", 5)).tag(300.0)
                    Text(L10n.tr("settings.minutes", 10)).tag(600.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            LaunchAtLoginToggle()
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quinary))
    }

    private func thresholdRow(
        _ title: String,
        value: Binding<Double>
    ) -> some View {
        HStack {
            Text(
                L10n.tr(
                    "auto_switch.threshold.format",
                    Int(value.wrappedValue),
                    title.lowercased(with: L10n.locale)
                )
            )
                .font(.callout)
            Spacer()
            Slider(value: value, in: 50...99, step: 1)
                .frame(width: 180)
        }
    }

}

/// Controles de cuenta compartida: tope personal de uso de 5 h y semanal para
/// dejar margen a la otra persona. La política automática y los colores de las
/// barras pasan a medirse contra el tope, y la marca vertical lo señala.
private struct SharedAccountControls: View {
    let profile: AccountProfile
    let state: AppState

    @State private var shared: Bool
    @State private var fiveHourCap: Double
    @State private var weeklyCap: Double
    /// Los ajustes quedan plegados una vez configurados; se despliegan al pulsar.
    @State private var expanded: Bool

    init(profile: AccountProfile, state: AppState) {
        self.profile = profile
        self.state = state
        let isShared = profile.sharedFiveHourCap != nil || profile.sharedWeeklyCap != nil
        _shared = State(initialValue: isShared)
        _fiveHourCap = State(initialValue: profile.sharedFiveHourCap ?? 60)
        _weeklyCap = State(initialValue: profile.sharedWeeklyCap ?? 60)
        _expanded = State(initialValue: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("shared.title"))
                        .font(.callout)
                    if shared {
                        Text(
                            L10n.tr(
                                "shared.caps_summary",
                                Int(fiveHourCap),
                                Int(weeklyCap)
                            )
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.tr("shared.disabled"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Toggle(L10n.tr("shared.reserve"), isOn: $shared)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: shared) { apply() }

                if shared {
                    capSlider(L10n.tr("shared.five_hour_cap"), value: $fiveHourCap)
                    capSlider(L10n.tr("shared.weekly_cap"), value: $weeklyCap)
                    Text(L10n.tr("shared.explanation"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.top, 2)
    }

    private func capSlider(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
                .font(.caption)
            Spacer()
            Slider(value: value, in: 10...90, step: 5)
                .frame(width: 160)
                .onChange(of: value.wrappedValue) { apply() }
            Text("\(Int(value.wrappedValue)) %")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private func apply() {
        state.setSharedCaps(
            fiveHour: shared ? fiveHourCap : nil,
            weekly: shared ? weeklyCap : nil,
            for: profile.accountUuid
        )
    }
}

/// Interruptor de arranque al iniciar sesión (solo funciona empaquetada como .app).
private struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle(L10n.tr("settings.launch_at_login"), isOn: $enabled)
            .toggleStyle(.switch)
            .onChange(of: enabled) {
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    enabled = SMAppService.mainApp.status == .enabled
                }
            }
    }
}
