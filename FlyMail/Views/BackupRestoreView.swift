import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 备份与恢复：单独独立的一页，不再是设置页里的一个 Section，
/// 也不再是“我的”页里一个打开设置页的按钮。
/// 从设置页进去是它，从“我的”页的备份与恢复进去也是它，同一页。
struct BackupRestoreView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
    @State private var restoring = false
    @State private var exporting = false
    @State private var exportURL: URL?
    @State private var exportResult: String?
    @State private var importing = false
    @State private var pendingBackup: ParsedBackup?
    @State private var confirmRestore = false
    @State private var restoreResult: String?

    var body: some View {
        Form {
            // 顶部留白：导航大标题“备份与恢复”下面不要直接贴着按钮，空出一段再放按钮
            Section {
                Color.clear.frame(height: 16)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            Section {
                Button {
                    exporting = true; exportResult = nil; exportURL = nil
                    Task {
                        do {
                            exportURL = try LocalBackup.exportURL(context: context)
                            exportResult = "备份已生成，点下面的分享把它存到“文件”或发到新手机上。"
                        } catch { exportResult = "导出失败：\(error.localizedDescription)" }
                        exporting = false
                    }
                } label: {
                    HStack { Label("导出本地备份", systemImage: "square.and.arrow.up"); Spacer(); if exporting { ProgressView() } }
                        .padding(.vertical, 6)
                }
                .disabled(exporting)
                .foregroundStyle(.primary)
                .buttonStyle(.plain)
                if let exportURL {
                    ShareLink(item: exportURL) { Label("分享备份 zip", systemImage: "square.and.arrow.up.on.square") }
                        .foregroundStyle(.primary)
                }
                if let exportResult { Text(exportResult).font(.callout).foregroundStyle(.secondary) }
                Button { importing = true } label: { Label("导入本地备份", systemImage: "square.and.arrow.down").padding(.vertical, 6) }
                    .foregroundStyle(.primary)
                    .buttonStyle(.plain)
                if let restoreResult { Text(restoreResult).font(.callout).foregroundStyle(.secondary) }
            } footer: {
                Text("导出的 zip 里是账户、文件夹设置、外观/同步/滑动设置、VIP、垃圾名单和本地草稿；不含邮件正文（恢复后同步一次就回来），也不含密码、授权码和令牌（恢复后每个账户重新输一次密码或重新登录，这是为了不让 zip 里留明文密码）。恢复会先替换掉当前账户和设置，确认前请先确认备份文件是对的。")
            }
            // 选完文件后在页面里直接显示“待恢复”，再由用户点按钮弹确认框。
            // 之前是在文件选择器的回调里立刻弹 confirmationDialog：这时选择器还在收起动画里，
            // 系统会把新弹窗吞掉，表现就是“选完文件没反应、恢复用不了”。
            if let pendingBackup {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("已读取备份").font(.headline)
                        Text(pendingBackup.summary).font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Button(role: .destructive) { confirmRestore = true } label: {
                        HStack {
                            Label("恢复这个备份", systemImage: "arrow.counterclockwise")
                            Spacer()
                            if restoring { ProgressView() }
                        }
                    }
                    .disabled(restoring)
                    Button("取消") { self.pendingBackup = nil }
                        .disabled(restoring)
                } header: { Text("待恢复") }
            }
            Section {
                Text("账户、邮件缓存、设置、草稿随系统 iCloud 备份恢复；密码、授权码、OAuth 令牌已改为可随备份恢复的存储级别，旧密钥在启动时自动重存迁移。附件和头像是可重新下载的缓存，不占备份空间，换机后重新下载。系统备份开关在 iOS 设置 > Apple ID > iCloud > iCloud 备份里开，App 里没有单独开关。")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("系统备份") }
        }
        .navigationTitle("备份与恢复")
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType.zip, UTType.data]) { result in
            switch result {
            case .success(let url):
                do {
                    pendingBackup = try LocalBackup.parse(url: url)
                    restoreResult = nil
                } catch { pendingBackup = nil; restoreResult = "导入失败：\(error.localizedDescription)" }
            case .failure(let e): restoreResult = "导入失败：\(e.localizedDescription)"
            }
        }
        .confirmationDialog("恢复这个备份？当前账户和设置会被备份里的内容替换，密码需要重新输入。", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("恢复", role: .destructive) { runRestore() }
            Button("取消", role: .cancel) {}
        }
    }

    private func runRestore() {
        guard let parsed = pendingBackup, !restoring else { return }
        restoring = true; restoreResult = nil
        // 恢复要删掉旧账户和它们的邮件缓存：先让界面放下旧数据（取消选中的邮件/文件夹），
        // 并停掉还在用旧账户的 IDLE 连接，否则界面或后台任务还拿着被删掉的对象，会崩溃或把新账户的同步挡住。
        app.selectedMessage = nil
        app.selectedMailbox = .unified
        app.messageOrder = []
        app.pendingRemoval = []
        app.archiveNeedsFolder = nil
        IdleManager.shared.stop()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            do {
                try LocalBackup.restore(parsed, context: context)
                restoreResult = "已恢复：\(parsed.summary)。请给每个账户重新输密码或重新登录，然后同步一次。"
                pendingBackup = nil
            } catch {
                context.rollback()
                restoreResult = "恢复失败：\(error.localizedDescription)"
            }
            IdleManager.shared.start(container: context.container)
            restoring = false
        }
    }
}

/// “我的”页里弹出来的备份与恢复：自带导航栏和完成按钮
struct BackupRestoreSheetView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            BackupRestoreView()
                .toolbar { Button("完成") { dismiss() } }
        }
    }
}
