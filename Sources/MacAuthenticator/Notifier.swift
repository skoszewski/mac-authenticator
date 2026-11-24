import Foundation
import UserNotifications
import Vault

/// Posts a macOS notification when a vault that worked fails. It does nothing outside an app bundle,
/// which has no notification center.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let bundled = Bundle.main.bundleURL.pathExtension == "app"
    /// Called with the vault of a clicked notification.
    var open: ((UUID) -> Void)?

    override init() {
        super.init()
        if bundled {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    /// Asks for the permission to notify; the system asks the person once and remembers the answer.
    func requestAuthorization() {
        guard bundled else {
            return
        }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
        }
    }

    /// Posts the problem of the vault; a later one of the same vault replaces it.
    func post(_ session: VaultSession, _ problem: VaultProblem) {
        guard bundled else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Vault \(session.profile.name): \(problem.title)"
        content.body = problem.suggestion
        content.userInfo = ["vault": session.profile.id.uuidString]
        let request = UNNotificationRequest(identifier: session.profile.id.uuidString, content: content, trigger: nil)
        Task {
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let id = (response.notification.request.content.userInfo["vault"] as? String).flatMap(UUID.init(uuidString:))
        await MainActor.run {
            if let id {
                open?(id)
            }
        }
    }
}
