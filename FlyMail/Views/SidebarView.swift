import SwiftUI
import SwiftData

struct SidebarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query private var outbox: [OutboxItem]
    @State private var editing: Account?
    /// 持久化的展开/折叠状态（逗号分隔的账户 ID）
    @AppStorage("sidebar.expanded") private var expandedRaw = ""
    @AppStorage("sidebar.collapsed") private var collapsedRaw = ""
    @AppStorage("sidebar.moreExpanded") private var moreRaw = ""

    static let roleOrder = ["inbox", "drafts", "sent", "archive", "junk", "trash"]
    static let roleNames = ["inbox": "收件箱", "drafts": "草稿箱", "sent": "已发送", "archive": "归档", "junk": "垃圾邮件", "trash": "废纸箱"]
    static let roleIcons = ["inbox": "tray", "drafts": "doc", "sent": "paperplane", "archive": "archivebox", "junk": "xmark.bin", "trash": "trash"]

    @Query private var allMessages: [MailMessage]
    @AppStorage(Prefs.smartOrder) private var smartOrder = Prefs.defaultSmartOrder
    @AppStorage(Prefs.smartHidden) private var smartHidden = ""
    @AppStorage(Prefs.vipList) private var vipRaw = ""

    private var sortedAccounts: [Account] { accounts.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) } }

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selectedMailbox) {
            Section {
                ForEach(Prefs.orderedSmart(smartOrder).filter { !set(smartHidden).contains($0) }, id: \.self) { k in
                    Label(Prefs.smartNames[k] ?? k, systemImage: Prefs.smartIcons[k] ?? "tray")
                        .badge(smartBadge(k))
                        .tag(Self.mailbox(forSmart: k))
                }
            }
            ForEach(sortedAccounts) { a in
                Section {
                    if isExpanded(a) {
                        ForEach(specialFolders(a)) { row($0) }
                        let others = customFolders(a)
                        if !others.isEmpty {
                            DisclosureGroup(isExpanded: binding(a, raw: $moreRaw)) {
                                ForEach(others) { row($0) }
                            } label: {
                                Label("更多文件夹", systemImage: "folder.badge.gearshape")
                            }
                        }
                    } else {
                        ForEach(visibleFolders(a).filter { a.collapsedRoles.contains($0.role) }) { row($0) }
                    }
                } header: {
                    header(a)
                }
            }
        }
        .listStyle(.sidebar)
        // dock 是悬浮盖在内容上面的，底部安全区再加 100pt，最后一行才能滑到 dock 上面完整露出来，不被 dock 盖住
        .safeAreaPadding(.bottom, 100)
        .navigationTitle("FlyMail")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { app.showingSearch = true } label: { Image(systemName: "magnifyingglass") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { app.composeDraft = ComposeDraft(accountID: defaultAccountID) } label: { Image(systemName: "square.and.pencil") }
                    .disabled(accounts.isEmpty)
            }
        }
        .refreshable { await MailSyncService(modelContainer: context.container).syncAll() }
        .sheet(item: $editing) { AccountEditView(account: $0) }
    }

    @AppStorage(Prefs.defaultAccount) private var defaultAccount = ""
    private var defaultAccountID: UUID? {
        UUID(uuidString: defaultAccount).flatMap { id in accounts.first { $0.id == id }?.id } ?? sortedAccounts.first?.id
    }

    static func mailbox(forSmart k: String) -> AppState.Mailbox {
        switch k {
        case "unified": return .unified
        case "outbox": return .outbox
        case "drafts", "archive", "junk", "trash": return .unifiedRole(k)
        default: return .smart(k)
        }
    }

    private func smartBadge(_ k: String) -> Int {
        _ = vipRaw
        switch k {
        case "unified": return unread(role: "inbox")
        case "junk": return unread(role: "junk")
        case "outbox": return outbox.count
        case "vip", "unread", "today": return allMessages.filter { !$0.isRead && SmartFilter.matches(k, $0) }.count
        default: return 0
        }
    }

    /// 按 账户+文件夹路径+UID 去重计数：重复文件夹对象里的同一封邮件只算一次，
    /// 否则统一收件箱的角标会比实际多出来（幻影未读的另一来源）。
    private func uniqueUnread(_ ms: [MailMessage]) -> Int {
        var seen = Set<String>()
        return ms.filter { !$0.isRead && seen.insert("\($0.folder?.account?.id.uuidString ?? "")|\($0.folder?.path ?? "")|\($0.uid)").inserted }.count
    }

    private func header(_ a: Account) -> some View {
        // 账户头只留展开符号 + 账户名：彩色圆点和头上的未读数都去掉，
        // 未读只在收件箱行里标注，避免两处重复。
        HStack(spacing: 6) {
            Button {
                withAnimation { toggle(a) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded(a) ? 90 : 0))
                        .font(.caption.weight(.semibold))
                    Text(a.displayName.isEmpty ? a.email : a.displayName).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button { editing = a } label: { Image(systemName: "gearshape") }.buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func row(_ f: MailFolder) -> some View {
        // 删除/移动进行中的邮件列表里已经隐藏了，侧边栏就别再算它，否则删完前会多一个
        let unread = ["trash", "sent", "drafts"].contains(f.role) ? 0
            : f.messages.filter { !$0.isRead && !app.pendingRemoval.contains($0.persistentModelID) }.count
        if f.role == "inbox" {
            // 收件箱行：蓝点 + 未读数，账户折叠时这一行也可见（collapsedRoles 默认含 inbox）
            HStack {
                Label(Self.folderName(f), systemImage: Self.roleIcons[f.role] ?? "folder")
                Spacer()
                if unread > 0 {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                    Text("\(unread)").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                }
            }
            .tag(AppState.Mailbox.folder(f.persistentModelID))
        } else {
            Label(Self.folderName(f), systemImage: Self.roleIcons[f.role] ?? "folder")
                .badge(unread)
                .tag(AppState.Mailbox.folder(f.persistentModelID))
        }
    }

    static func folderName(_ f: MailFolder) -> String { f.role.isEmpty ? f.name : (roleNames[f.role] ?? f.name) }

    /// 未隐藏的文件夹，按用户排序（未自定义时：特殊文件夹固定顺序在前）
    static func orderedFolders(_ a: Account) -> [MailFolder] {
        var seen = Set<String>()
        let special = a.folders.filter { !$0.role.isEmpty }
            .sorted { (roleOrder.firstIndex(of: $0.role) ?? 99) < (roleOrder.firstIndex(of: $1.role) ?? 99) }
            .filter { seen.insert($0.role).inserted }
        let specialPaths = Set(special.map(\.path))
        let others = a.folders.filter { !specialPaths.contains($0.path) }.sorted { $0.name < $1.name }
        let base = special + others
        guard base.contains(where: { $0.sortIndex >= 0 }) else { return base }
        return base.enumerated().sorted { l, r in
            let li = l.element.sortIndex >= 0 ? l.element.sortIndex : 1000 + l.offset
            let ri = r.element.sortIndex >= 0 ? r.element.sortIndex : 1000 + r.offset
            return li < ri
        }.map(\.element)
    }

    private func visibleFolders(_ a: Account) -> [MailFolder] {
        Self.orderedFolders(a).filter { !a.hiddenFolders.contains($0.path) }
    }

    private func specialFolders(_ a: Account) -> [MailFolder] {
        var seen = Set<String>()
        return visibleFolders(a).filter { !$0.role.isEmpty && seen.insert($0.role).inserted }
    }

    private func customFolders(_ a: Account) -> [MailFolder] {
        let special = Set(specialFolders(a).map(\.path))
        return visibleFolders(a).filter { !special.contains($0.path) && $0.role.isEmpty }
    }

    private func unread(role: String) -> Int {
        uniqueUnread(accounts.flatMap(\.folders).filter { $0.role == role }.flatMap(\.messages))
    }

    // MARK: 折叠状态
    private func set(_ raw: String) -> Set<String> { Set(raw.split(separator: ",").map(String.init)) }

    private func isExpanded(_ a: Account) -> Bool {
        let id = a.id.uuidString
        if accounts.count <= 1 { return !set(collapsedRaw).contains(id) }   // 单账户默认展开
        return set(expandedRaw).contains(id)                                // 多账户默认折叠
    }

    private func toggle(_ a: Account) {
        let id = a.id.uuidString
        if accounts.count <= 1 {
            var c = set(collapsedRaw); if c.contains(id) { c.remove(id) } else { c.insert(id) }
            collapsedRaw = c.joined(separator: ",")
        } else {
            var e = set(expandedRaw); if e.contains(id) { e.remove(id) } else { e.insert(id) }
            expandedRaw = e.joined(separator: ",")
        }
    }

    private func binding(_ a: Account, raw: Binding<String>) -> Binding<Bool> {
        let id = a.id.uuidString
        return Binding(get: { set(raw.wrappedValue).contains(id) }, set: { on in
            var s = set(raw.wrappedValue); if on { s.insert(id) } else { s.remove(id) }
            raw.wrappedValue = s.joined(separator: ",")
        })
    }
}

