import Foundation
import UserNotifications

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Powiadamiamy tylko o D1 (krytyczne). Reszta żyje cicho w popoverze,
    /// bo narzędzie, które budzi co kwadrans, zostaje wyłączone po tygodniu.
    static func post(_ finding: Finding) {
        let content = UNMutableNotificationContent()
        content.title = "\(finding.detector.label): \(finding.title)"
        content.body = finding.summary
        content.sound = .default
        let request = UNNotificationRequest(identifier: finding.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
