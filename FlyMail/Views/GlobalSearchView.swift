import SwiftUI
import SwiftData

/// 全局搜索：本地缓存全文 + 服务器 IMAP SEARCH（所有账户并行），合并去重按时间排序
struct GlobalSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query(sort: \MailMessage.date, order: .reverse) private var all: [MailMessage]
    @AppStorage("search.history") private var historyRaw = ""

    @State private var text = ""
    @State private var scope = "all"
    @State private var accountID: UUID?
    @State private var role = ""
    @State private var range = 0
    @State private var onlyAttach = false
    @State private var onlyUnread = false
    @State private var onlyFlagged = false
    @State private var serverIDs: Set<PersistentIdentifier> = []
    @State private var searchingServer = false
    @State private var submitted = ""

    private var history: [String] { historyRaw.split(separator: "\u{1F}").map(String.init) }

    private var results: [MailMessage] {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty || onlyAttach || onlyUnread || onlyFlagged else { return [] }
        let since = range > 0 ? Calendar.current.date(byAdding: .day, value: -range, to: .now) : nil
        return all.filter { m in
            if let accountID, m.folder?.account?.id != accountID { return false }
            if !role.isEmpty, m.folder?.role != role { return false }
            if let since, m.date < since { return false }
            if onlyAttach && !(m.hasAttachment || !m.attachmentNames.isEmpty) { return false }
            if onlyUnread && m.isRead { return false }
            if onlyFlagged && !m.isFlagged { return false }
            if q.isEmpty || serverIDs.contains(m.persistentModelID) { return true }
            switch scope {
            case "from": return m.from.localizedCaseInsensitiveContains(q)
            case "subject": return m.subject.localizedCaseInsensitiveContains(q)
            case "body": return m.bodyText.localizedCaseInsensitiveContains(q) || m.snippet.localizedCaseInsensitiveContains(q)
            default:
                return m.subject.localizedCaseInsensitiveContains(q) || m.from.localizedCaseInsensitiveContains(q)
                    || m.to.localizedCaseInsensitiveContains(q) || m.snippet.localizedCaseInsensitiveContains(q)
                    || m.bodyText.localizedCaseInsensitiveContains(q)
            }
        }.prefix(500).map { $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                filters
                if text.isEmpty && !history.isEmpty {
                    Section {
                        ForEach(history, id: \.self) { h in
                            Button { text = h; submit() } label: { Label(h, systemImage: "clock.arrow.circlepath") }.foregroundStyle(.primary)
                        }
                        Button("清除搜索记录", role: .destructive) { historyRaw = "" }
                    } header: { Text("最近搜索") }
                }
                let r = results
                if !r.isEmpty || searchingServer {
                    Section {
                        ForEach(r) { m in
                            Button { open(m, in: r) } label: { SearchRow(message: m, query: text) }.buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text("\(r.count) 个结果")
                            if searchingServer { ProgressView().controlSize(.mini); Text("正在搜索服务器…") }
                        }
                    }
                } else if !submitted.isEmpty {
                    ContentUnavailableView.search(text: submitted)
                }
            }
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索所有账户的邮件")
            .searchScopes($scope) {
                Text("全部").tag("all"); Text("发件人").tag("from"); Text("主题").tag("subject"); Text("正文").tag("body")
            }
            .onSubmit(of: .search) { submit() }
            .onChange(of: text) { _, v in if v.isEmpty { serverIDs = []; submitted = "" } }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
        }
    }

    private var filters: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Menu {
                        Picker("账户", selection: $accountID) {
                            Text("所有账户").tag(UUID?.none)
                            ForEach(accounts) { Text($0.email).tag(Optional($0.id)) }
                        }
                    } label: { chip(accountID.flatMap { id in accounts.first { $0.id == id }?.email } ?? "所有账户", on: accountID != nil) }
                    Menu {
                        Picker("文件夹", selection: $role) {
                            Text("所有文件夹").tag("")
                            ForEach(SidebarView.roleOrder, id: \.self) { Text(SidebarView.roleNames[$0] ?? $0).tag($0) }
                        }
                    } label: { chip(role.isEmpty ? "所有文件夹" : (SidebarView.roleNames[role] ?? role), on: !role.isEmpty) }
                    Menu {
                        Picker("时间", selection: $range) {
                            Text("不限时间").tag(0); Text("最近 1 周").tag(7); Text("最近 1 个月").tag(30); Text("最近 1 年").tag(365)
                        }
                    } label: { chip(range == 0 ? "不限时间" : "最近 \(range) 天", on: range > 0) }
                    Button { onlyAttach.toggle() } label: { chip("有附件", on: onlyAttach) }
                    Button { onlyUnread.toggle() } label: { chip("未读", on: onlyUnread) }
                    Button { onlyFlagged.toggle() } label: { chip("星标", on: onlyFlagged) }
                }
                .buttonStyle(.plain)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        }
    }

    private func chip(_ t: String, on: Bool) -> some View {
        Text(t).font(.footnote.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill)))
            .foregroundStyle(on ? Color.accentColor : .primary)
    }

    private func submit() {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        submitted = q
        var h = history.filter { $0 != q }; h.insert(q, at: 0)
        historyRaw = h.prefix(10).joined(separator: "\u{1F}")
        searchingServer = true
        let svc = MailSyncService(modelContainer: context.container)
        let s = scope, acc = accountID
        Task {
            let ids = await svc.globalServerSearch(q, scope: s, accountID: acc)
            if submitted == q { serverIDs = Set(ids) }
            searchingServer = false
        }
    }

    private func open(_ m: MailMessage, in list: [MailMessage]) {
        app.messageOrder = list.map(\.persistentModelID)
        app.selectedMessage = m.persistentModelID
        dismiss()
    }
}

struct SearchRow: View {
    let message: MailMessage
    let query: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(from: message.from, size: 34, allowRemote: message.spamScore < SpamFilter.threshold)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(highlight(displayName(message.from))).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(MessageDetailView.shortDate(message.date)).font(.caption).foregroundStyle(.secondary)
                }
                Text(highlight(message.subject)).font(.subheadline).lineLimit(1)
                Text(highlight(excerpt)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 4) {
                    if let a = message.folder?.account {
                        Circle().fill(Prefs.palette[a.colorIndex % Prefs.palette.count]).frame(width: 6, height: 6)
                        Text(a.email)
                    }
                    if let f = message.folder { Text("· " + SidebarView.folderName(f)) }
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    /// 正文中命中位置附近的片段
    private var excerpt: String {
        let body = message.bodyText.isEmpty ? message.snippet : message.bodyText
        guard !query.isEmpty, let r = body.range(of: query, options: .caseInsensitive) else { return message.snippet }
        let start = body.index(r.lowerBound, offsetBy: -30, limitedBy: body.startIndex) ?? body.startIndex
        let end = body.index(r.upperBound, offsetBy: 80, limitedBy: body.endIndex) ?? body.endIndex
        return (start > body.startIndex ? "…" : "") + body[start..<end].replacingOccurrences(of: "\n", with: " ")
    }

    private func highlight(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        guard !query.isEmpty else { return a }
        var searchStart = s.startIndex
        while let r = s.range(of: query, options: .caseInsensitive, range: searchStart..<s.endIndex) {
            if let ar = Range(r, in: a) {
                a[ar].foregroundColor = .accentColor
                a[ar].inlinePresentationIntent = .stronglyEmphasized
            }
            searchStart = r.upperBound
        }
        return a
    }
}
