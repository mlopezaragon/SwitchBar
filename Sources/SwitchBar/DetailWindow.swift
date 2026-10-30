import SwiftUI
import ServiceManagement
import SwitchBarCore

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

                if let notice = state.autoSwitchMonitoringNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
                Text("SwitchBar")
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
        let usage = state.usageByAccount[profile.id]
        let isActive = profile.id == state.activeProfileID
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(profile.needsLogin ? Color.orange : (isActive ? Color.green : Color.secondary.opacity(0.4)))
                    .frame(width: 8, height: 8)
                Text(profile.emailAddress)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let plan = profile.plan {
                    PlanBadge(
                        plan: plan,
                        organizationName: profile.organizationName,
                        fiveHourLimitRemoved: usage?.fiveHourLimitRemoved
                    )
                }

                Spacer(minLength: 12)

                if isActive {
                    Text(L10n.tr("account.active"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .fixedSize()
                } else {
                    if profile.id == state.nextAutoSwitchTarget {
                        NextAutoSwitchBadge()
                    }
                    Button(L10n.tr("account.change_to")) {
                        state.switchTo(profile.id)
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
                        state.removeProfile(profile.id)
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
                if usage?.fiveHourLimitRemoved != true {
                    UsageRing(label: L10n.tr("usage.five_hours"), window: usage?.fiveHour)
                }
                UsageRing(label: L10n.tr("usage.week"), window: usage?.sevenDay,
                          unreported: usage?.weeklyLimitUnreported == true)
                UsageRing(label: L10n.tr("usage.fable"), window: usage?.sevenDayOpus)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            let resetRows = LimitResetText.rows(usage?.limitResets)
            if !resetRows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.tr("limit_resets.title"), systemImage: "arrow.counterclockwise")
                        .font(.callout.weight(.medium))
                    ForEach(resetRows, id: \.self) { row in
                        Text(row)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .help(L10n.tr("limit_resets.help"))
            }

            SharedAccountControls(
                profile: profile,
                state: state,
                hasFiveHourLimit: usage?.fiveHourLimitRemoved != true
            )

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

    /// Previsión de cupo y ritmos medidos de cada plan.
    private var paceDetails: some View {
        let summary = state.paceSummary
        return VStack(alignment: .leading, spacing: 5) {
            Text(L10n.tr("forecast.title"))
                .font(.callout.weight(.medium))
            if let forecast = state.coverageForecast {
                Label(CoverageText.summary(forecast), systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(CoverageText.isUrgent(forecast) ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let pace = summary.currentPace, let email = summary.activeEmail {
                Text(L10n.tr("pace.current", email, Int(pace.rounded())))
                    .font(.caption)
            }
            ForEach(summary.plans, id: \.plan) { entry in
                Text(
                    L10n.tr(
                        "pace.plan",
                        entry.plan.displayName,
                        Int(entry.pace.pointsPerHour.rounded()),
                        ResetFormatter.duration(entry.pace.measured)
                    )
                )
                .font(.caption)
            }
            if let ratio = capacityRatio(summary) {
                Text(ratio)
                    .font(.caption)
            }
            if summary.plans.isEmpty {
                Text(L10n.tr("pace.unmeasured"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(L10n.tr("forecast.explanation"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Cuánto rinde el plan con más cupo frente al que menos: con el mismo
    /// trabajo, el que tiene más cupo gasta menos puntos por hora.
    private func capacityRatio(_ summary: AppState.PaceSummary) -> String? {
        guard summary.plans.count >= 2,
              let roomiest = summary.plans.min(by: { $0.pace.pointsPerHour < $1.pace.pointsPerHour }),
              let tightest = summary.plans.max(by: { $0.pace.pointsPerHour < $1.pace.pointsPerHour }),
              roomiest.plan != tightest.plan, roomiest.pace.pointsPerHour > 0 else { return nil }
        let ratio = tightest.pace.pointsPerHour / roomiest.pace.pointsPerHour
        return L10n.tr(
            "pace.ratio",
            roomiest.plan.displayName,
            ratio.formatted(.number.precision(.fractionLength(1)).locale(L10n.locale)),
            tightest.plan.displayName
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

            Toggle(
                L10n.tr("auto_switch.expiring_quota"),
                isOn: $state.anticipateExpiringQuota
            )
            .toggleStyle(.switch)
            .controlSize(.small)

            Text(
                state.anticipateExpiringQuota
                    ? L10n.tr("auto_switch.choice_explanation") + " "
                        + L10n.tr("auto_switch.expiring_quota.explanation")
                    : L10n.tr("auto_switch.choice_explanation")
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(
                L10n.tr("auto_switch.pace"),
                isOn: $state.switchByPace
            )
            .toggleStyle(.switch)
            .controlSize(.small)

            Text(L10n.tr("auto_switch.pace.explanation"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if state.switchByPace {
                paceDetails
            }

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

            HStack {
                Text(
                    L10n.tr(
                        "settings.version",
                        Bundle.main.object(
                            forInfoDictionaryKey: "CFBundleShortVersionString"
                        ) as? String ?? "—"
                    )
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("settings.check_updates")) {
                    AppUpdater.checkForUpdates()
                }
            }
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
    /// Sin límite de 5 h (Ultra verificada) su tope no se ofrece, aunque se
    /// conserva por si el límite volviera.
    let hasFiveHourLimit: Bool

    @State private var shared: Bool
    @State private var fiveHourCap: Double
    @State private var weeklyCap: Double
    /// Los ajustes quedan plegados una vez configurados; se despliegan al pulsar.
    @State private var expanded: Bool

    init(profile: AccountProfile, state: AppState, hasFiveHourLimit: Bool) {
        self.profile = profile
        self.state = state
        self.hasFiveHourLimit = hasFiveHourLimit
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
                    if hasFiveHourLimit {
                        capSlider(L10n.tr("shared.five_hour_cap"), value: $fiveHourCap)
                    }
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
            for: profile.id
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
