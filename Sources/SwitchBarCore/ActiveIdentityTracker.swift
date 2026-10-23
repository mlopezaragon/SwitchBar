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
    public private(set) var profileID: String?

    public init(profileID: String? = nil) {
        self.profileID = profileID
    }

    public mutating func observe(
        profileID newProfileID: String,
        expectedAppProfileID: String?
    ) -> ActiveIdentityChange {
        guard newProfileID != profileID else {
            return .unchanged
        }
        profileID = newProfileID
        return newProfileID == expectedAppProfileID
            ? .appInitiated
            : .manual
    }
}
