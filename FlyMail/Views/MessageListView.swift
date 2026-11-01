import SwiftUI
import SwiftData

struct MessageListContainer: View {
    let mailbox: AppState.Mailbox?
    @Environment(\.modelContext) private var context

    var body: some View {
        switch mailbox {
        case .outbox: OutboxListView()
        case .unifiedRole(let role): MessageListView(folder: nil, role: role).id(role)
        case .smart(let kind): MessageListView(folder: nil, role: "", smart: kind).id("smart-" + kind)
        case .folder(let id):
            if let f = context.model(for: id) as? MailFolder {
                MessageListView(folder: f).id(id)
            }
        default: MessageListView(folder: nil)
        }
    }
}

/// 智能邮箱的筛选规则（排除垃圾邮件与废纸箱）
enum SmartFilter {
    static func matches(_ kind: String, _ m: MailMessage) -> Bool {
        let r = m.folder?.role ?? ""
        guard r != "junk", r != "trash" else { return false }
        switch kind {
        case "vip": return VIPStore.contains(m.from)
        case "unread": return !m.isRead && r != "sent" && r != "drafts"
        case "flagged": return m.isFlagged
        case "today": return Calendar.current.isDateInToday(m.date) && r != "sent" && r != "drafts"
        case "attachments": return m.hasAttachment || !m.attachmentNames.isEmpty
        default: return false
        }
    }
}

/// 收件箱顶部的筛选：不再只有一个未读开关，全部/未读/已读/VIP 都在这里
enum ListFilter: String, CaseIterable {
    case all, unread, read, vip
    var title: String { switch self { case .all: "全部"; case .unread: "未读"; case .read: "已读"; case .vip: "VIP" } }
    func matches(_ m: MailMessage) -> Bool {
        switch self {
        case .all: return true
        case .unread: return !m.isRead
        case .read: return m.isRead
        case .vip: return VIPStore.contains(m.from)
        }
    }
}

struct MessageListView: View {
    let folder: MailFolder?
    let role: String
    let smart: String?
    @State private var confirmEmpty = false
    @Query private var allFolders: [MailFolder]
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query private var messages: [MailMessage]
    @State private var search = ""
    @State private var filter: ListFilter = .all
    @State private var showingDisplaySettings = false
    @AppStorage(Prefs.unifiedHiddenAccounts) private var unifiedHiddenRaw = ""
    @State private var remoteUIDs: Set<UInt32>?
    @State private var remoteMessageIDs: Set<PersistentIdentifier> = []
    @State private var moving: MailMessage?
    @AppStorage(Prefs.grouping) private var grouping = false
    @AppStorage(Prefs.vipList) private var vipRaw = ""
    @AppStorage(Prefs.leading1) private var leading1 = "read"
    @AppStorage(Prefs.leading2) private var leading2 = "flag"
    @AppStorage(Prefs.trailing1) private var trailing1 = "delete"
    @AppStorage(Prefs.trailing2) private var trailing2 = "archive"

    init(folder: MailFolder?, role: String = "inbox", smart: String? = nil) {
        self.folder = folder
        self.smart = smart
        self.role = folder?.role ?? role
        let r = self.role
        if let fid = folder?.persistentModelID {
            _messages = Query(filter: #Predicate<MailMessage> { $0.folder?.persistentModelID == fid },
                              sort: \.date, order: .reverse)
        } else if smart != nil {
            _messages = Query(sort: \.date, order: .reverse)
        } else {
            _messages = Query(filter: #Predicate<MailMessage> { $0.folder?.role == r },
                              sort: \.date, order: .reverse)
        }
    }

    /// 总收件箱 = 全部账户的收件箱聚合（不是单个文件夹、不是智能邮箱）
    private var isUnifiedInbox: Bool { folder == nil && smart == nil && role == "inbox" }
    private var unifiedHiddenAccounts: Set<String> { Set(unifiedHiddenRaw.split(separator: ",").map(String.init)) }

    private var filtered: [MailMessage] {
        _ = vipRaw
        let hidden = unifiedHiddenAccounts
        return messages.filter { m in
            !app.pendingRemoval.contains(m.persistentModelID) &&
            // 总收件箱展示设置：关掉的邮箱不聚合进来，只是不显示，邮箱和邮件本身不受影响
            !(isUnifiedInbox && !hidden.isEmpty && hidden.contains(m.folder?.account?.id.uuidString ?? "")) &&
            filter.matches(m) &&
            (smart == nil || SmartFilter.matches(smart!, m)) &&
            (search.isEmpty || m.subject.localizedCaseInsensitiveContains(search) || m.from.localizedCaseInsensitiveContains(search)
             || m.bodyText.localizedCaseInsensitiveContains(search) || (remoteUIDs?.contains(m.uid) ?? false)
             || remoteMessageIDs.contains(m.persistentModelID))
        }
    }

    /// 按主题归并会话：(最新一封, 数量, 组内未读数)
    struct Row: Identifiable { let message: MailMessage; let count: Int; let unreadCount: Int
        var id: PersistentIdentifier { message.persistentModelID } }

    private var rows: [Row] {
        guard grouping else { return filtered.map { Row(message: $0, count: 1, unreadCount: $0.isRead ? 0 : 1) } }
        var order: [String] = [], groups: [String: (MailMessage, Int, Int)] = [:]
        for m in filtered {
            let k = (m.folder?.account?.id.uuidString ?? "") + "|" + Self.threadKey(m.subject)
            if let g = groups[k] { groups[k] = (g.0, g.1 + 1, g.2 + (m.isRead ? 0 : 1)) }
            else { groups[k] = (m, 1, m.isRead ? 0 : 1); order.append(k) }
        }
        return order.compactMap { groups[$0] }.map { Row(message: $0.0, count: $0.1, unreadCount: $0.2) }
    }

    static func threadKey(_ subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespaces)
        while let r = s.range(of: #"^(re|fw|fwd|回复|答复|转发)\s*[:：]\s*"#, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(r)
        }
        return s.lowercased()
    }

    var body: some View {
        @Bindable var app = app
        // 下拉动画 bug：空状态之前是 .overlay 盖在列表上面，位置固定在屏幕中间，下拉时只有大标题“收件箱”往下动，
        // 中间的托盘图标和“没有邮件/下拉刷新”两行字一动不动。改成列表里的一行，跟着列表内容一起滚，下拉时图标
        // 就跟着大标题一起往下动，不再是中间不动的。selection 仍用 List(selection:) + ForEach tag，和原来一样。
        List(selection: $app.selectedMessage) {
            if rows.isEmpty {
                ContentUnavailableView("没有邮件", systemImage: "tray", description: Text("下拉刷新"))
                    .frame(maxWidth: .infinity, minHeight: 520)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(rows) { row in
                    let m = row.message
                    MessageRow(message: m, threadCount: row.count, threadUnread: row.unreadCount).tag(m.persistentModelID)
                        .swipeActions(edge: .leading) {
                            swipeButton(leading1, m); swipeButton(leading2, m)
                        }
                        .swipeActions(edge: .trailing) {
                            if role == "trash" || role == "junk" {
                                Button("永久删除", systemImage: "trash.slash", role: .destructive) { MessageActions.deletePermanently(m, app: app, context: context) }
                                Button("恢复", systemImage: "tray.and.arrow.up") { MessageActions.restore(m, app: app, context: context) }.tint(.green)
                            } else {
                                swipeButton(trailing1, m); swipeButton(trailing2, m)
                            }
                        }
                        .contextMenu { MessageMenuItems(message: m, movingMessage: $moving) }
                }
            }
        }
        .listStyle(.plain)
        // dock 是悬浮盖在内容上面的，底部安全区再加 100pt，最后一行才能滑到 dock 上面完整露出来，不被 dock 盖住
        .safeAreaPadding(.bottom, 100)
        .onChange(of: rows.map(\.id), initial: true) { _, ids in app.messageOrder = ids }
        // 右下角新建邮件悬浮按钮：悬浮在顶部工具栏和底部导航中间的这块区域，才用强调色——顶部和底部的按钮
        // 本身不用加强调色（顶部是系统玻璃、底部是黑字灰玻璃 pill，保持原样）。强调色不用系统 accentColor（用户说太丑），
        // 直接用用户发来的 Zoho 样图里量到的蓝：RGB 32,129,241（#2081F1），但这次不是实心色块，是蓝色液态玻璃：
        // glassEffect regular + 蓝染色，真机上会折射模糊，仍醒目，和详情页底部栏同一套材质。
        // 用 offset 而不用 padding 定位：点击区就只有 56pt 的圆，
        // 不会用一块 76×152 的透明 padding 挡住右下角的邮件行；dock 是悬浮的，列表底就是屏幕底，
        // dock 现在高约 60 + 底部 2pt，offset -84 正好把按钮放在 dock 上面约 22pt，像 Zoho 那样，不再飘到中间
        .overlay(alignment: .bottomTrailing) {
            Button { app.composeDraft = ComposeDraft(accountID: nil) } label: {
                // 玻璃直接作用在内容上（而不是 ZStack 里垫一个 Circle）：
                // 图标会自动走玻璃的 vibrancy；interactive 给按下时的缩放 + 高光反馈，和系统按钮一样。
                Image(systemName: "square.and.pencil")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .glassEffect(.regular.tint(Color(red: 32/255, green: 129/255, blue: 241/255)).interactive(), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(x: -16, y: -84)
        }
        .navigationTitle(title)
        .confirmationDialog(role == "trash" ? "永久删除废纸箱中的所有邮件？" : "永久删除所有垃圾邮件？",
                            isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button(role == "trash" ? "清空废纸箱" : "清空垃圾邮件", role: .destructive) {
                let targets = folder.map { [$0] } ?? allFolders.filter { $0.role == role }
                MessageActions.empty(targets, app: app, context: context)
            }
        } message: { Text("此操作无法撤销。") }
        // 导航栏下面的搜索框拿掉了：它会被导航栏盖住一部分，而且工具栏里
        // 已经有放大镜按钮，点进去就是聚合搜索，不需要两处搜索
        .toolbar {
            // 列表里的搜索只搜当前邮箱；点放大镜进聚合搜索，可搜全部账户、服务器上的旧邮件
            ToolbarItem { Button { app.showingSearch = true } label: { Image(systemName: "magnifyingglass") } }
            // 筛选菜单：全部/未读/已读/VIP，不再只有一个未读开关
            ToolbarItem {
                Menu {
                    Picker("筛选", selection: $filter) {
                        ForEach(ListFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
            }
            // 更多菜单：编辑显示设置（只在总收件箱出现，里面直接改哪些邮箱在总收件箱展示）
            ToolbarItem {
                Menu {
                    if isUnifiedInbox {
                        Button("编辑显示设置") { showingDisplaySettings = true }
                    }
                    Button("全部标记已读") {
                        for m in filtered where !m.isRead { MessageActions.toggleRead(m, app: app, context: context) }
                    }.disabled(filtered.allSatisfy(\.isRead))
                } label: { Image(systemName: "ellipsis.circle") }
            }
            if role == "trash" || role == "junk" {
                ToolbarItem { Button(role == "trash" ? "清空废纸箱" : "清空", role: .destructive) { confirmEmpty = true }.disabled(messages.isEmpty) }
            }
        }
        .sheet(isPresented: $showingDisplaySettings) {
            NavigationStack {
                UnifiedInboxDisplaySettingsView()
                    .toolbar { Button("完成") { showingDisplaySettings = false } }
            }
        }
        .refreshable { await refresh() }
        .sheet(item: $moving) { MoveFolderPicker(message: $0) }
        .task {
            if let f = folder, f.messages.isEmpty, !f.isInbox { await refresh() }
            else if folder == nil, smart == nil, role != "inbox", messages.isEmpty { await refresh() }
        }
    }

    @ViewBuilder
    private func swipeButton(_ action: String, _ m: MailMessage) -> some View {
        switch action {
        case "read":
            Button(m.isRead ? "未读" : "已读", systemImage: m.isRead ? "envelope.badge" : "envelope.open") {
                MessageActions.toggleRead(m, app: app, context: context)
            }.tint(.blue)
        case "flag":
            Button(m.isFlagged ? "取消星标" : "星标", systemImage: "star") { MessageActions.toggleFlag(m, app: app, context: context) }.tint(.orange)
        case "archive":
            if MessageActions.canArchive(m) {
                Button("归档", systemImage: "archivebox") { MessageActions.archive(m, app: app, context: context) }.tint(.purple)
            }
        case "delete":
            Button("删除", systemImage: "trash", role: .destructive) { MessageActions.delete(m, app: app, context: context) }
        case "junk":
            Button("垃圾邮件", systemImage: "xmark.bin") { MessageActions.markJunk(m, app: app, context: context) }.tint(.brown)
        case "move":
            Button("移动", systemImage: "folder") { moving = m }.tint(.gray)
        case "vip":
            Button("VIP", systemImage: "star.circle") { VIPStore.toggle(m.from) }.tint(.yellow)
        default: EmptyView()
        }
    }

    private func refresh() async {
        let svc = MailSyncService(modelContainer: context.container)
        do {
            if let f = folder { try await svc.syncFolder(id: f.persistentModelID) }
            else if role == "inbox" || smart != nil { await svc.syncAll() }
            else { await svc.syncRole(role) }
        } catch { app.lastError = error.localizedDescription }
    }

    private var title: String {
        if let f = folder { return f.role.isEmpty ? f.name : (SidebarView.roleNames[f.role] ?? f.name) }
        if let smart { return Prefs.smartNames[smart] ?? smart }
        // 首页默认就是这个：全部账户的收件箱，不再叫“统一收件箱”
        return role == "inbox" ? "收件箱" : "全部" + (SidebarView.roleNames[role] ?? "")
    }

    private func remoteSearch() async {
        guard !search.isEmpty else { return }
        // 统一收件箱（folder 为 nil）以前不走服务器搜索，超出同步范围的旧邮件搜不到；
        // 现在走聚合服务器搜索（全部账户），结果按本地记录 ID 合入列表。
        if let f = folder {
            remoteUIDs = Set((try? await MailSyncService(modelContainer: context.container)
                .remoteSearch(folderID: f.persistentModelID, query: search)) ?? [])
        } else {
            remoteMessageIDs = Set(await MailSyncService(modelContainer: context.container)
                .globalServerSearch(search, scope: "all", accountID: nil))
        }
    }
}

/// 总收件箱的展示设置：哪些邮箱在总收件箱里展示，关掉只是不聚合显示，
/// 邮箱本身、里面的邮件、同步都不受影响，随时可以再打开。
struct UnifiedInboxDisplaySettingsView: View {
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @AppStorage(Prefs.unifiedHiddenAccounts) private var hiddenRaw = ""

    private var hidden: Set<String> { Set(hiddenRaw.split(separator: ",").map(String.init)) }
    private func setShown(_ account: Account, _ shown: Bool) {
        var h = hidden
        if shown { h.remove(account.id.uuidString) } else { h.insert(account.id.uuidString) }
        hiddenRaw = h.joined(separator: ",")
    }

    var body: some View {
        Form {
            Section {
                ForEach(accounts) { a in
                    Toggle(isOn: Binding(
                        get: { !hidden.contains(a.id.uuidString) },
                        set: { setShown(a, $0) }
                    )) {
                        VStack(alignment: .leading) {
                            Text(a.displayName.isEmpty ? a.email : a.displayName)
                            Text(a.email).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                if !hidden.isEmpty {
                    Button("显示全部邮箱") { hiddenRaw = "" }
                }
            } footer: {
                Text("关掉的邮箱不会出现在总收件箱里，邮箱本身和里面的邮件不受影响。")
            }
        }
        .navigationTitle("显示设置")
    }
}

struct MessageRow: View {
    let message: MailMessage
    var threadCount = 1
    var threadUnread = 0
    @AppStorage(Prefs.density) private var density = 1
    @AppStorage(Prefs.previewLines) private var previewLines = 2
    @AppStorage(Prefs.showAvatars) private var showAvatars = true

    private var isSpam: Bool { message.spamScore >= SpamFilter.threshold || message.folder?.role == "junk" }

    var body: some View {
        HStack(alignment: .top, spacing: density == 0 ? 6 : 10) {
            // 分组时最新一封已读、组里还有旧的未读，列表也要亮蓝点，
            // 否则列表看着全已读、侧边栏却还数着那 1 封
            Circle().fill((message.isRead && threadUnread == 0) ? .clear : Color.accentColor).frame(width: 8, height: 8).padding(.top, 6)
            if showAvatars && density > 0 {
                AvatarView(from: message.from, size: density == 2 ? 44 : 36, allowRemote: !isSpam)
            }
            VStack(alignment: .leading, spacing: density == 2 ? 4 : 2) {
                HStack(spacing: 4) {
                    if let acc = message.folder?.account {
                        Circle().fill(Prefs.palette[acc.colorIndex % Prefs.palette.count]).frame(width: 6, height: 6)
                    }
                    Text(displayName(message.from)).font(density == 0 ? .subheadline.bold() : .headline).lineLimit(1)
                    if threadCount > 1 { Text("\(threadCount)").font(.caption2).padding(.horizontal, 5).background(Capsule().fill(.quaternary)) }
                    if VIPStore.contains(message.from) { Image(systemName: "star.circle.fill").foregroundStyle(.yellow).font(.caption) }
                    Spacer()
                    if message.spamScore >= SpamFilter.threshold && message.folder?.role != "junk" {
                        Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red).font(.caption)
                    }
                    if message.isFlagged { Image(systemName: "star.fill").foregroundStyle(.orange).font(.caption) }
                    if message.hasAttachment || !message.attachmentNames.isEmpty { Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary) }
                    Text(message.date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                }
                Text(message.subject).font(density == 0 ? .caption : .subheadline).lineLimit(1)
                if previewLines > 0 && !message.snippet.isEmpty && density > 0 {
                    Text(message.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(previewLines)
                }
            }
        }
        .padding(.vertical, [0, 2, 6][min(max(density, 0), 2)])
    }
}

func displayName(_ from: String) -> String {
    if let l = from.firstIndex(of: "<") {
        let n = from[..<l].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        if !n.isEmpty { return n }
    }
    return MIMEParser.addresses(from).first ?? from
}

struct OutboxListView: View {
    @Query(sort: \OutboxItem.sendAt) private var items: [OutboxItem]
    @Environment(\.modelContext) private var context

    @Environment(AppState.self) private var app
    @State private var drafts: [ComposeDraft] = []

    var body: some View {
        List {
            if !drafts.isEmpty {
                Section("本地草稿") {
                    ForEach(drafts) { d in
                        Button {
                            app.composeDraft = d
                        } label: {
                            VStack(alignment: .leading) {
                                Text(d.subject.isEmpty ? "(无主题)" : d.subject).font(.headline)
                                Text(d.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { idx in idx.forEach { LocalDraftStore.delete(drafts[$0].id) }; drafts = LocalDraftStore.all() }
                }
            }
            Section("待发送") {
            ForEach(items) { i in
                VStack(alignment: .leading) {
                    Text(i.subject.isEmpty ? "(无主题)" : i.subject).font(.headline)
                    Text("收件人：\(i.to)").font(.caption)
                    Text("计划发送：\(i.sendAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    if let e = i.lastError { Text("失败 \(i.attempts) 次：\(e)").font(.caption).foregroundStyle(.red) }
                }
            }
            .onDelete { idx in idx.forEach { context.delete(items[$0]) }; try? context.save() }
        }
        }
        .onAppear { drafts = LocalDraftStore.all() }
        .onChange(of: app.composeDraft == nil) { _, _ in drafts = LocalDraftStore.all() }
        .overlay { if items.isEmpty && drafts.isEmpty { ContentUnavailableView("发件箱为空", systemImage: "paperplane") } }
        .navigationTitle("发件箱")
        .toolbar { Button("立即发送") { Task { await OutboxService(modelContainer: context.container).flushDue() } } }
    }
}
