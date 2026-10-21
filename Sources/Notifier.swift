import Foundation
import UserNotifications

/// 本地通知。只有在真正的 .app 包里运行才可用（命令行直接跑二进制会崩），
/// 所以这里做了防御。
final class Notifier {
    static let shared = Notifier()

    private var available: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private var didPrepare = false

    func prepare() {
        guard available, !didPrepare else { return }
        didPrepare = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
