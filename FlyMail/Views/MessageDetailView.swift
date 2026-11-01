import SwiftUI
import SwiftData
import WebKit
import QuickLook

/// 悬浮栏风格：系统液态玻璃，不是白填充仿的。
/// 用系统 SDK 的 glassEffect regular，系统在真机上渲染折射、高光和模糊，
/// 工具栏里的按钮不要再套一层，因为 iOS 27 工具栏本身已经是液态玻璃。
extension View {
    func liquidGlass<S: Shape>(_ shape: S) -> some View {
        self
            .background { shape.glassEffect(.regular, in: shape) }
    }
}

struct MessageDetailView: View {
    let message: MailMessage
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @State private var loading = false
    @State private var showHTML = true
    @State private var htmlHeight: CGFloat = 200
    @State private var showRecipients = false
    @AppStorage(Prefs.showAvatars) private var showAvatars = true
    @AppStorage(Prefs.vipList) private var vipRaw = ""
    @State private var moving: MailMessage?
    @State private var previewURL: URL?
    @State private var attachmentURLs: [String: URL] = [:]

    @State private var confirmDelete = false
    /// 本封邮件是否已允许加载远程图片（默认拦截；VIP 发件人视为可信，自动加载）
    @State private var loadRemote = false

    private var allowRemote: Bool { loadRemote || VIPStore.contains(message.from) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerView
                Text(message.subject).font(.title2.bold()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if message.spamScore >= SpamFilter.threshold && message.folder?.role != "junk" { spamBanner }
                if message.folder?.role == "drafts" {
                    Button("继续编辑草稿", systemImage: "square.and.pencil") { resumeDraft() }.buttonStyle(.borderedProminent)
                }
                if !message.attachmentNames.isEmpty { attachmentsSection }
                if loading && !message.bodyLoaded {
                    VStack(spacing: 8) { ProgressView(); Text("正在从服务器拉取正文…").font(.callout).foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity).padding(.top, 30)
                }
                else if showHTML, let html = message.bodyHTML {
                    if !allowRemote && MailHTMLView.hasRemoteContent(html) { remoteBanner }
                    MailHTMLView(html: html, allowRemote: allowRemote, height: $htmlHeight).frame(height: htmlHeight)
                } else {
                    PlainTextBody(text: message.bodyText)
                }
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 90)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .overlay(alignment: .bottom) { bottomBar }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { navCapsule }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if message.bodyHTML != nil {
                        Button(showHTML ? "显示纯文本" : "显示网页格式", systemImage: showHTML ? "doc.plaintext" : "doc.richtext") { showHTML.toggle() }
                    }
                    MessageMenuItems(message: message, movingMessage: $moving)
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("更多")
            }
        }
        // 不用自定义材质盖导航栏：iOS 27 系统导航栏本身就是液态玻璃。
        .navigationBarTitleDisplayMode(.inline)
        .task(id: message.persistentModelID) { await load(); refreshAttachmentURLs() }
        .onChange(of: message.persistentModelID) { _, _ in loadRemote = false }
        .sheet(item: $moving) { MoveFolderPicker(message: $0) }
        .sheet(item: $previewURL) { QuickLookView(url: $0).ignoresSafeArea() }
        .confirmationDialog(isTrashLike ? "永久删除这封邮件？" : "删除这封邮件？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { deleteCurrent() }
        }
    }

    private var isTrashLike: Bool { ["trash", "junk"].contains(message.folder?.role ?? "") }
    private var index: Int? { app.messageOrder.firstIndex(of: message.persistentModelID) }

    private var navCapsule: some View {
        // 上一封 / 下一封：只留工具栏自带的那一层液态玻璃，不再自己套 Capsule 玻璃，
        // 否则两层玻璃叠在一起会发灰、边缘发重，看起来很奇怪。
        HStack(spacing: 0) {
            Button { step(-1) } label: { Image(systemName: "chevron.up").frame(width: 34, height: 30) }
                .accessibilityLabel("上一封")
                .disabled((index ?? 0) <= 0)
            Divider().frame(height: 16)
            Button { step(1) } label: { Image(systemName: "chevron.down").frame(width: 34, height: 30) }
                .accessibilityLabel("下一封")
                .disabled(index.map { $0 >= app.messageOrder.count - 1 } ?? true)
        }
        .font(.body.weight(.semibold))
    }

    private func step(_ d: Int) {
        guard let i = index, app.messageOrder.indices.contains(i + d) else { return }
        app.selectedMessage = app.messageOrder[i + d]
    }

    // 苹果邮件式底部栏：左侧一个胶囊里放删除 / 移动 / 回复，右侧单独一个写信圆钮
    private var bottomBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                barButton("trash") { confirmDelete = true }
                barButton("folder") { moving = message }
                Menu {
                    Button("回复", systemImage: "arrowshape.turn.up.left") { reply(all: false) }
                    Button("全部回复", systemImage: "arrowshape.turn.up.left.2") { reply(all: true) }
                    Button("转发", systemImage: "arrowshape.turn.up.right") { forward() }
                } label: {
                    Image(systemName: "arrowshape.turn.up.left").font(.title3).frame(width: 52, height: 46)
                        .accessibilityLabel("回复与转发")
                } primaryAction: { reply(all: false) }
            }
            .padding(.horizontal, 6)
            // 玻璃只做背景层：按钮在玻璃上面，点击不再被玻璃层挡住；
            // 这组是操作按钮（删除/移动/回复），没有选中态，所以不做滑动滑块，
            // 滑动滑块只给有选中态的连体按钮组（比如底部 dock 的栏目）
            .background { Capsule().glassEffect(.regular, in: Capsule()) }
            Spacer()
            Button {
                app.composeDraft = ComposeDraft(accountID: message.folder?.account?.id)
            } label: {
                Image(systemName: "square.and.pencil").font(.title3).frame(width: 50, height: 50)
                    .accessibilityLabel("写邮件")
            }
            .background { Circle().glassEffect(.regular, in: Circle()) }
        }
        .padding(.horizontal, 18).padding(.bottom, 8)
    }

    private func barButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.title3).frame(width: 52, height: 46) }
            .accessibilityLabel(icon == "trash" ? "删除" : "移动")
    }

    /// 被拦截远程内容时的提示条（类似苹果邮件的“隐私保护”），一键加载本封邮件的图片
    private var remoteBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo").foregroundStyle(.secondary)
            Text("已拦截远程图片，防止发件人得知你是否打开了邮件。")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("加载图片") { withAnimation(.snappy) { loadRemote = true } }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func deleteCurrent() {
        let next: PersistentIdentifier? = index.flatMap { i in
            app.messageOrder.indices.contains(i + 1) ? app.messageOrder[i + 1] : (i > 0 ? app.messageOrder[i - 1] : nil)
        }
        if isTrashLike { MessageActions.deletePermanently(message, app: app, context: context) }
        else { MessageActions.delete(message, app: app, context: context) }
        if UIDevice.current.userInterfaceIdiom == .pad { app.selectedMessage = next }
    }

    private func load() async {
        loading = !message.bodyLoaded; defer { loading = false }
        do { try await MailSyncService(modelContainer: context.container).loadBody(messageID: message.persistentModelID) }
        catch { if !message.bodyLoaded { app.lastError = error.localizedDescription } }
        // 打开一封时顺带预取上一封/下一封的正文（不标已读），点上一封/下一封时直接读缓存，
        // 不用再经历一次 TLS + 登录 + 整封下载。后台任务，不阻塞当前页。
        Task {
            let order = app.messageOrder
            guard let idx = order.firstIndex(of: message.persistentModelID) else { return }
            let svc = MailSyncService(modelContainer: context.container)
            for i in [idx - 1, idx + 1] where order.indices.contains(i) {
                await svc.prefetchBody(messageID: order[i])
            }
        }
    }

    private var isSpam: Bool { message.spamScore >= SpamFilter.threshold || message.folder?.role == "junk" }

    private var headerView: some View {
        HStack(alignment: .top, spacing: 10) {
            if showAvatars { AvatarView(from: message.from, size: 40, allowRemote: !isSpam) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(displayName(message.from)).font(.headline).lineLimit(1)
                    if VIPStore.contains(message.from) { Image(systemName: "star.circle.fill").foregroundStyle(.yellow).font(.caption) }
                    Spacer(minLength: 6)
                    Text(Self.shortDate(message.date)).font(.subheadline).foregroundStyle(.secondary)
                }
                Button { withAnimation(.snappy) { showRecipients.toggle() } } label: {
                    HStack(spacing: 3) {
                        Text("收件人：").foregroundStyle(.secondary)
                        Text(MIMEParser.addresses(message.to + "," + message.cc).map { displayName($0) }.joined(separator: "、")).lineLimit(1)
                        Image(systemName: "chevron.right").font(.caption2).rotationEffect(.degrees(showRecipients ? 90 : 0)).foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.plain)
                if showRecipients {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("发件人：\(message.from)")
                        Text("收件人：\(message.to)")
                        if !message.cc.isEmpty { Text("抄送：\(message.cc)") }
                        Text(message.date.formatted(date: .complete, time: .standard))
                    }
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    static func shortDate(_ d: Date) -> String {
        let c = Calendar.current
        if c.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if c.isDateInYesterday(d) { return "昨天" }
        // 苹果邮件那样：本周内显示星期几（星期四），而不是月日
        if let days = c.dateComponents([.day], from: c.startOfDay(for: d), to: c.startOfDay(for: .now)).day,
           days >= 0, days < 7 {
            let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "EEEE"
            return f.string(from: d)
        }
        if c.isDate(d, equalTo: .now, toGranularity: .year) { return d.formatted(.dateTime.month().day()) }
        return d.formatted(date: .numeric, time: .omitted)
    }

    private var spamBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("这封邮件可能是垃圾邮件（评分 \(message.spamScore)）", systemImage: "exclamationmark.shield.fill")
                .font(.subheadline.bold()).foregroundStyle(.red)
            ForEach(message.spamReasons, id: \.self) { Text("· \($0)").font(.caption) }
            HStack {
                Button("移到垃圾邮件") { MessageActions.markJunk(message, app: app, context: context) }
                Button("不是垃圾邮件") { MessageActions.notJunk(message, app: app, context: context) }
            }
            .buttonStyle(.bordered).font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(message.attachmentNames, id: \.self) { name in
                HStack {
                    Button {
                        Task { await open(name) }
                    } label: { Label(name, systemImage: Self.attachmentIcon(name)).lineLimit(1) }
                    Spacer()
                    if let url = attachmentURLs[name] {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                }
                .font(.callout)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// 按扩展名给附件配图标，一眼分清图片/文档/压缩包
    static func attachmentIcon(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo"
        case "pdf": return "doc.richtext"
        case "doc", "docx", "pages", "txt", "rtf", "md": return "doc.text"
        case "xls", "xlsx", "csv", "numbers": return "tablecells"
        case "ppt", "pptx", "key": return "play.rectangle"
        case "zip", "rar", "7z", "gz", "tar": return "doc.zipper"
        case "mp3", "m4a", "wav", "aac": return "waveform"
        case "mp4", "mov", "m4v": return "film"
        case "ics": return "calendar"
        default: return "paperclip"
        }
    }

    private func fileURL(_ name: String) -> URL? {
        guard let f = message.folder, let a = f.account else { return nil }
        return AttachmentStore.url(accountID: a.id, folder: f.path, uidValidity: f.uidValidity, uid: message.uid, name: name)
    }

    private func refreshAttachmentURLs() {
        var d: [String: URL] = [:]
        for n in message.attachmentNames {
            if let u = fileURL(n), FileManager.default.fileExists(atPath: u.path) { d[n] = u }
        }
        attachmentURLs = d
    }

    private func open(_ name: String) async {
        if attachmentURLs[name] == nil {
            do { try await MailSyncService(modelContainer: context.container).ensureAttachments(messageID: message.persistentModelID) }
            catch { app.lastError = error.localizedDescription; return }
            refreshAttachmentURLs()
        }
        previewURL = attachmentURLs[name]
    }

    private func resumeDraft() {
        guard let f = message.folder, let a = f.account else { return }
        var d = ComposeDraft(accountID: a.id)
        d.to = message.to; d.cc = message.cc; d.subject = message.subject; d.body = message.bodyText
        if !message.messageID.isEmpty { d.messageID = message.messageID }
        d.serverDraftUID = message.uid; d.serverDraftFolder = f.path
        app.composeDraft = d
    }

    private var quoted: String {
        "\n\n在 \(message.date.formatted()) ，\(message.from) 写道：\n" +
        message.bodyText.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
    }

    private func reply(all: Bool) {
        let acc = message.folder?.account
        var d = ComposeDraft(accountID: acc?.id)
        d.to = message.from
        if all {
            let me = acc?.email.lowercased() ?? ""
            d.cc = (MIMEParser.addresses(message.to) + MIMEParser.addresses(message.cc))
                .filter { $0.lowercased() != me }.joined(separator: ", ")
        }
        d.subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
        d.body = (acc?.signature ?? "") + quoted
        d.inReplyTo = message.messageID
        app.composeDraft = d
    }

    private func forward() {
        let acc = message.folder?.account
        var d = ComposeDraft(accountID: acc?.id)
        d.subject = "Fwd: \(message.subject)"
        d.body = (acc?.signature ?? "") + "\n\n---------- 转发的邮件 ----------\n发件人：\(message.from)\n主题：\(message.subject)\n\n\(message.bodyText)"
        app.composeDraft = d
    }
}

extension URL: Identifiable { public var id: String { absoluteString } }

/// QLPreviewController 的 SwiftUI 包装
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UINavigationController {
        let q = QLPreviewController()
        q.dataSource = context.coordinator
        q.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak q] _ in q?.dismiss(animated: true) })
        return UINavigationController(rootViewController: q)
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
