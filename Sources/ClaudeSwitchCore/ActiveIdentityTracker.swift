import Foundation

public enum ActiveIdentityChange: Sendable, Equatable {
    case unchanged
    case appInitiated
    case manual
}

/// Distingue un cambio real de cuenta de las escrituras ordinarias que
/// Claude Code hace en `~/.claude.json`.
///
/// La fecha de modificación del fichero no basta para detectar `/login`: el
/// archivo contiene más estado y puede reescribirse aunque la cuenta activa
/// siga siendo la misma.
public struct ActiveIdentityTracker: Sendable {
    public private(set) var accountUuid: String?

    public init(accountUuid: String? = nil) {
        self.accountUuid = accountUuid
    }

    public mutating func observe(
        accountUuid newAccountUuid: String,
        expectedAppAccountUuid: String?
    ) -> ActiveIdentityChange {
        guard newAccountUuid != accountUuid else {
            return .unchanged
        }
        accountUuid = newAccountUuid
        return newAccountUuid == expectedAppAccountUuid
            ? .appInitiated
            : .manual
    }
}
