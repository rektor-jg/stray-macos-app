import Foundation
import UserNotifications

enum Notifier {
    private static var asked = false

    /// Zgoda proszona LENIWIE — dopiero przy pierwszym znalezisku, które naprawdę
    /// wymaga powiadomienia.
    ///
    /// Pytanie przy każdym starcie było natrętne i bezcelowe: większość uruchomień
    /// kończy się bez jednego alarmu, więc użytkownik płacił oknem dialogowym
    /// za funkcję, z której nigdy nie skorzystał.
    private static func ensureAuthorized(_ then: @escaping @Sendable (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                then(true)
            case .notDetermined:
                guard !asked else { return then(false) }
                asked = true
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    then(granted)
                }
            default:
                then(false)
            }
        }
    }

    /// Powiadamiamy tylko o D1 (krytyczne). Reszta żyje cicho w popoverze,
    /// bo narzędzie, które budzi co kwadrans, zostaje wyłączone po tygodniu.
    static func post(_ finding: Finding) {
        ensureAuthorized { granted in
            guard granted else { return }
            deliver(finding)
        }
    }

    private static func deliver(_ finding: Finding) {
        let content = UNMutableNotificationContent()
        content.title = "\(finding.detector.label): \(finding.title)"
        content.body = finding.summary
        content.sound = .default
        let request = UNNotificationRequest(identifier: finding.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
