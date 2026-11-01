import SwiftUI
import SwiftData
import BackgroundTasks

@main
struct FlyMailApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    let container: ModelContainer
    @State private var app = AppState()

    init() {
        Prefs.registerDefaults()
        // SwiftData 默认库在 Application Support 目录，本来就随系统 iCloud 备份恢复，
        // 不用改存储位置（改位置会丢掉已有缓存）；附件、头像在 Caches 里，是可重新下载的缓存，
        // 本来就不该占备份空间，换机后重新下载即可。
        container = try! ModelContainer(for: Account.self, MailFolder.self, MailMessage.self, OutboxItem.self)
        // 旧密钥若是 ThisDeviceOnly，换机备份恢复会丢：启动时重存一遍，改成可备份级别
        let ctx = ModelContext(container)
        if let accounts = try? ctx.fetch(FetchDescriptor<Account>()) {
            for a in accounts { KeychainStore.migrateToBackupable(accountID: a.id) }
        }
        BackgroundScheduler.shared.register(container: container)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .onAppear { BackgroundScheduler.shared.scheduleAll() }
        }
        .modelContainer(container)
    }
}

/// 全局 UI 状态（选中的邮箱/文件夹/邮件）
@Observable
final class AppState {
    enum Mailbox: Hashable {
        case unified                // 收件箱：首页默认，全部账户的收件箱
        case folder(PersistentIdentifier)
        case outbox
        /// 跨账户的特殊文件夹：archive / junk / trash
        case unifiedRole(String)
        /// 智能邮箱：vip / unread / flagged / today / attachments
        case smart(String)
    }
    var selectedMailbox: Mailbox? = .unified
    /// 当前列表的显示顺序（详情页上一封/下一封）
    var messageOrder: [PersistentIdentifier] = []
    var showingSearch = false
    var selectedMessage: PersistentIdentifier?
    var showingAccountSetup = false
    var composeDraft: ComposeDraft?
    var lastError: String?
    /// 乐观删除/移动中的邮件（列表中先隐藏）
    var pendingRemoval: Set<PersistentIdentifier> = []
    /// 归档时账户没有归档文件夹，等待用户确认创建
    var archiveNeedsFolder: MailMessage?
    var showingSettings = false
    /// 底部 dock 栏目：首页 / 邮件 / AI / 我的（“我的”和其他栏目一样是栏目，不是弹页）
    enum DockTab { case home, mail, ai, my }
    var dockTab: DockTab = .home
}
