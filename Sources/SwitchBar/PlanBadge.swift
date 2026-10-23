import SwiftUI
import SwitchBarCore

/// Etiqueta con el plan de la cuenta. Las de una organización (Team y
/// Enterprise) van en azul para distinguirlas de un vistazo de las personales.
struct PlanBadge: View {
    let plan: AccountPlan
    var organizationName: String?

    var body: some View {
        Text(plan.displayName)
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
        guard plan.isOrganization else { return L10n.tr("account.plan.personal") }
        if let organizationName {
            return L10n.tr("account.plan.organization_named", organizationName)
        }
        return L10n.tr("account.plan.organization")
    }
}
