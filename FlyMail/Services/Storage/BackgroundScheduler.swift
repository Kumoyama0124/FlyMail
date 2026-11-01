import Foundation
import BackgroundTasks
import SwiftData
import UserNotifications

final class BackgroundScheduler {
    static let shared = BackgroundScheduler()
    static let refreshID = "com.gymbull.flymail.refresh"
    static let outboxID = "com.gymbull.flymail.outbox"
    private var container: ModelContainer?

    func register(container: ModelContainer) {
        self.container = container
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshID, using: nil) { task in
            self.handle(task) { c in _ = await MailSyncService(modelContainer: c).syncAll(notify: true) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.outboxID, using: nil) { task in
            self.handle(task) { c in _ = await OutboxService(modelContainer: c).flushDue() }
        }
    }

    private func handle(_ task: BGTask, work: @escaping (ModelContainer) async -> Void) {
        scheduleAll()
        guard let container else { task.setTaskCompleted(success: false); return }
        let t = Task {
            await work(container)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { t.cancel() }
    }

    func scheduleAll(nextOutbox: Date? = nil) {
        // 后台刷新跟“更新频率”设置走：手动(-1)不排后台收信；定时则按该分钟数，
        // 但 iOS 最短约 15 分钟，低于 15 分钟仍按 15 分钟排（前台 IDLE/轮询不受此限）。
        let interval = UserDefaults.standard.integer(forKey: Prefs.syncInterval)
        if interval != -1 {
            let r = BGAppRefreshTaskRequest(identifier: Self.refreshID)
            r.earliestBeginDate = .now.addingTimeInterval(TimeInterval(max(15, interval)) * 60)
            try? BGTaskScheduler.shared.submit(r)
        }

        // 定时发送：iOS 不保证准点执行，App 前台时也会由计时器补发
        let p = BGProcessingTaskRequest(identifier: Self.outboxID)
        p.requiresNetworkConnectivity = true
        p.earliestBeginDate = nextOutbox ?? .now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(p)
    }
}

enum NotificationService {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    static func notifyNewMail(account: String, from: String, subject: String) {
        let c = UNMutableNotificationContent()
        c.title = from.isEmpty ? account : from
        c.subtitle = account
        c.body = subject
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
