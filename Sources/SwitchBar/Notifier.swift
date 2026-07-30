import Foundation
import UserNotifications
import SwitchBarCore

/// Notificaciones nativas. Sin bundle (ejecución con `swift run`) se omiten
/// en silencio: UNUserNotificationCenter requiere una app empaquetada.
enum Notifier {
    private static var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static func requestPermission() {
        guard isBundled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        guard isBundled else {
            NSLog(
                "%@",
                L10n.tr("notification.omitted_unbundled", title, body)
            )
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
