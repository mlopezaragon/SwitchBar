import SwiftUI
import SwitchBarCore

/// Etiqueta con el plan de la cuenta. Las de una organización (Team y
/// Enterprise) van en azul para distinguirlas de un vistazo de las personales.
/// Una Ultra verificada, que ya no tiene límite de 5 h, lleva un sello.
struct PlanBadge: View {
    let plan: AccountPlan
    var organizationName: String?
    /// El servidor ya no informa de su ventana de 5 h. `nil` mientras no
    /// hay datos de uso: no se sabe si está verificada.
    var fiveHourLimitRemoved: Bool? = nil

    private var isVerifiedUltra: Bool {
        plan == .ultra && fiveHourLimitRemoved == true
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(plan.displayName)
            if isVerifiedUltra {
                Image(systemName: "checkmark.seal.fill")
                    .imageScale(.small)
            }
        }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(
                    plan.isOrganization
                        ? AnyShapeStyle(Color.blue.opacity(0.15))
                        : AnyShapeStyle(.quaternary)
                )
            )
            .foregroundStyle(
                plan.isOrganization ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.secondary)
            )
            .fixedSize()
            .help(explanation)
    }

    private var explanation: String {
        if plan == .ultra, let fiveHourLimitRemoved {
            return fiveHourLimitRemoved
                ? L10n.tr("account.plan.ultra_verified")
                : L10n.tr("account.plan.ultra_unverified")
        }
        guard plan.isOrganization else { return L10n.tr("account.plan.personal") }
        if let organizationName {
            return L10n.tr("account.plan.organization_named", organizationName)
        }
        return L10n.tr("account.plan.organization")
    }
}
