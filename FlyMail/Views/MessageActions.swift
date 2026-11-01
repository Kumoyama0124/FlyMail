import SwiftUI
import SwiftData

/// 邮件操作：先更新界面（乐观），失败时回滚并提示
@MainActor
enum MessageActions {
    static func toggleRead(_ m: MailMessage, app: AppState, context: ModelContext) {
        let new = !m.isRead
        m.isRead = new; try? context.save()
        perform(m, op: .seen(new), app: app) { m.isRead = !new; try? context.save() }
    }

    static func toggleFlag(_ m: MailMessage, app: AppState, context: ModelContext) {
        let new = !m.isFlagged
        m.isFlagged = new; try? context.save()
        perform(m, op: .flag(new), app: app) { m.isFlagged = !new; try? context.save() }
    }

    static func delete(_ m: MailMessage, app: AppState, context: ModelContext) {
        let trash = m.folder?.account?.folder(role: "trash")?.path
        remove(m, op: .delete(trash: trash), app: app, context: context)
    }

    /// 归档。Gmail 的归档文件夹是“所有邮件”(\\All)：从收件箱 MOVE 过去即去掉收件箱标签。
    static func archive(_ m: MailMessage, app: AppState, context: ModelContext) {
        guard let account = m.folder?.account else { return }
        guard let archive = account.folder(role: "archive") else { app.archiveNeedsFolder = m; return }
        guard archive.path != m.folder?.path else { return }
        remove(m, op: .move(to: archive.path), app: app, context: context)
    }

    /// 在服务器上创建归档文件夹，然后归档该邮件
    static func createArchiveAndArchive(_ m: MailMessage, app: AppState, context: ModelContext) {
        guard let account = m.folder?.account else { return }
        let chinese = ["qq", "163", "126", "sina", "139", "189", "sohu", "aliyun"].contains(account.providerID)
        let name = chinese ? "归档" : "Archive"
        let path = ModifiedUTF7.encode(name)
        let cfg = AccountConfig(account)
        Task { @MainActor in
            do {
                let imap = try await cfg.openIMAP()
                do { try await imap.create(path) } catch {
                    // 已存在则忽略
                    if !(error.localizedDescription.uppercased().contains("EXIST")) { await imap.logout(); throw error }
                }
                await imap.logout()
                let f = MailFolder(path: path, name: name, isInbox: false, account: account)
                f.role = "archive"
                context.insert(f); try? context.save()
                archive(m, app: app, context: context)
            } catch { app.lastError = "创建归档文件夹失败：\(error.localizedDescription)" }
        }
    }

    static func markJunk(_ m: MailMessage, app: AppState, context: ModelContext) {
        guard let junk = m.folder?.account?.folder(role: "junk") else { app.lastError = "该账户没有找到垃圾邮件文件夹"; return }
        SpamFilter.learn(from: m.from, isSpam: true)
        remove(m, op: .markJunk(junk: junk.path), app: app, context: context)
    }

    static func notJunk(_ m: MailMessage, app: AppState, context: ModelContext) {
        SpamFilter.learn(from: m.from, isSpam: false)
        if m.folder?.role == "junk" {
            remove(m, op: .notJunk(inbox: "INBOX"), app: app, context: context)
        } else {
            m.spamScore = 0; m.spamReasons = []; try? context.save()
        }
    }

    static func restore(_ m: MailMessage, app: AppState, context: ModelContext) {
        remove(m, op: .move(to: "INBOX"), app: app, context: context)
    }

    static func deletePermanently(_ m: MailMessage, app: AppState, context: ModelContext) {
        remove(m, op: .delete(trash: nil), app: app, context: context)
    }

    /// 清空文件夹（废纸箱/垃圾邮件）
    static func empty(_ folders: [MailFolder], app: AppState, context: ModelContext) {
        for f in folders {
            guard let a = f.account else { continue }
            let cfg = AccountConfig(a), path = f.path, ids = f.messages.map(\.persistentModelID)
            ids.forEach { app.pendingRemoval.insert($0) }
            Task { @MainActor in
                do {
                    try await MailActions.run(cfg, folder: path, uids: [], op: .emptyFolder)
                    for id in ids { if let m = context.model(for: id) as? MailMessage { context.delete(m) } }
                    try? context.save()
                } catch { app.lastError = "清空失败：\(error.localizedDescription)" }
                ids.forEach { app.pendingRemoval.remove($0) }
            }
        }
    }

    static func move(_ m: MailMessage, to folder: MailFolder, app: AppState, context: ModelContext) {
        guard folder.path != m.folder?.path else { return }
        remove(m, op: .move(to: folder.path), app: app, context: context)
    }

    static func canArchive(_ m: MailMessage) -> Bool { m.folder?.role != "archive" }

    private static func remove(_ m: MailMessage, op: MailOp, app: AppState, context: ModelContext) {
        let id = m.persistentModelID
        app.pendingRemoval.insert(id)
        if app.selectedMessage == id { app.selectedMessage = nil }
        let fid = m.folder?.persistentModelID, uid = m.uid
        perform(m, op: op, app: app, onSuccess: {
            // 按 账户+文件夹路径+UID 删除本地记录（包括重复文件夹对象里的重复行，
            // 否则删了一行、统一收件箱里还剩一行，再删那行时服务器上已没有它，就会报错）
            let path = m.folder?.path
            let samePathFolders = m.folder?.account?.folders.filter { $0.path == path } ?? []
            if !samePathFolders.isEmpty {
                for f in samePathFolders { f.messages.filter { $0.uid == uid }.forEach { context.delete($0) } }
            } else if let fid, let f = context.model(for: fid) as? MailFolder {
                f.messages.filter { $0.uid == uid }.forEach { context.delete($0) }
            } else if let msg = context.model(for: id) as? MailMessage { context.delete(msg) }
            try? context.save()
            app.pendingRemoval.remove(id)
        }, rollback: { app.pendingRemoval.remove(id) })
    }

    private static func perform(_ m: MailMessage, op: MailOp, app: AppState,
                                onSuccess: @escaping () -> Void = {}, rollback: @escaping () -> Void) {
        guard let folder = m.folder, let account = folder.account else { return }
        let cfg = AccountConfig(account), path = folder.path, uid = m.uid
        Task { @MainActor in
            do {
                try await MailActions.run(cfg, folder: path, uids: [uid], op: op)
                onSuccess()
            } catch {
                // 服务器上已没有该文件夹/邮件（别处已删、残留行）：本地删掉就是正确结果，
                // 不再弹“操作失败”。网络等其他错误仍回滚并提示。
                if error.localizedDescription.uppercased().contains("NONEXISTENT") {
                    onSuccess()
                } else {
                    rollback()
                    app.lastError = "操作失败，已撤销：\(error.localizedDescription)"
                }
            }
        }
    }
}

/// 列表滑动/右键菜单/详情工具栏共用的菜单项
struct MessageMenuItems: View {
    let message: MailMessage
    @Binding var movingMessage: MailMessage?
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @AppStorage(Prefs.vipList) private var vipRaw = ""

    var body: some View {
        Button(message.isRead ? "标为未读" : "标为已读", systemImage: message.isRead ? "envelope.badge" : "envelope.open") {
            MessageActions.toggleRead(message, app: app, context: context)
        }
        Button(message.isFlagged ? "取消星标" : "星标", systemImage: message.isFlagged ? "star.slash" : "star") {
            MessageActions.toggleFlag(message, app: app, context: context)
        }
        let role = message.folder?.role ?? ""
        if role != "archive" {
            Button("归档", systemImage: "archivebox") { MessageActions.archive(message, app: app, context: context) }
        }
        if role == "junk" || message.spamScore >= SpamFilter.threshold {
            Button("不是垃圾邮件", systemImage: "checkmark.shield") { MessageActions.notJunk(message, app: app, context: context) }
        }
        if role != "junk" {
            Button("标记为垃圾邮件", systemImage: "xmark.bin") { MessageActions.markJunk(message, app: app, context: context) }
        }
        Button(VIPStore.contains(message.from) ? "取消 VIP" : "设为 VIP", systemImage: "star.circle") { VIPStore.toggle(message.from) }
        Button("移动到…", systemImage: "folder") { movingMessage = message }
        if role == "trash" || role == "junk" {
            Button("恢复到收件箱", systemImage: "tray.and.arrow.up") { MessageActions.restore(message, app: app, context: context) }
            Button("永久删除", systemImage: "trash.slash", role: .destructive) { MessageActions.deletePermanently(message, app: app, context: context) }
        } else {
            Button("删除", systemImage: "trash", role: .destructive) { MessageActions.delete(message, app: app, context: context) }
        }
    }
}

struct MoveFolderPicker: View {
    let message: MailMessage
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context

    var body: some View {
        NavigationStack {
            List((message.folder?.account?.folders ?? []).sorted { $0.name < $1.name }) { f in
                Button {
                    MessageActions.move(message, to: f, app: app, context: context); dismiss()
                } label: {
                    Label(f.name, systemImage: f.isInbox ? "tray" : "folder")
                }
                .disabled(f.path == message.folder?.path)
            }
            .navigationTitle("移动到")
            .toolbar { Button("取消") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }
}
