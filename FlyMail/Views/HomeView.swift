import SwiftUI
import SwiftData

/// 首页：主页面。不是邮件列表，而是一张总览 —— 个人卡片、未读统计、
/// 快捷邮箱入口、账户入口；点快捷入口就切到“邮件”栏目看列表。
struct HomeView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query private var allMessages: [MailMessage]
    @AppStorage(Prefs.myNickname) private var nickname = ""
    @AppStorage(Prefs.mySignature) private var signature = ""
    @AppStorage(Prefs.myEmail) private var myEmail = ""
    @State private var avatarImage: UIImage?
    @AppStorage(Prefs.homeShortcuts) private var homeShortcutsRaw = Prefs.defaultHomeShortcuts
    @State private var showingShortcutEdit = false

    private var unreadCount: Int {
        allMessages.filter { !$0.isRead && $0.folder?.role == "inbox" }.count
    }
    private var todayCount: Int {
        allMessages.filter { Calendar.current.isDateInToday($0.date) && $0.folder?.role != "sent" }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 个人卡片
                    HStack(spacing: 14) {
                        Group {
                            if let avatarImage {
                                Image(uiImage: avatarImage).resizable().scaledToFill()
                            } else {
                                ZStack {
                                    Circle().fill(Color.accentColor.opacity(0.15))
                                    Text(String((nickname.isEmpty ? "我" : nickname).prefix(1)))
                                        .font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(width: 56, height: 56).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(nickname.isEmpty ? "你好" : "你好，\(nickname)")
                                .font(.title3.weight(.semibold))
                            if !signature.isEmpty { Text(signature).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                            Text(myEmail.isEmpty ? (accounts.first?.email ?? "") : myEmail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding().background { RoundedRectangle(cornerRadius: 20).fill(.white).overlay { RoundedRectangle(cornerRadius: 20).stroke(.black.opacity(0.06), lineWidth: 0.5) } }.shadow(color: .black.opacity(0.06), radius: 10, y: 2)

                    // 统计
                    HStack(spacing: 12) {
                        statCard("\(unreadCount)", "未读")
                        statCard("\(todayCount)", "今天")
                        statCard("\(accounts.count)", "账户")
                    }

                    // 快捷邮箱：可编辑，点右上角“编辑”增删、拖动排序、恢复默认
                    HStack {
                        Text("快捷入口").font(.headline)
                        Spacer()
                        Button("编辑") { showingShortcutEdit = true }.font(.subheadline).foregroundStyle(Color.accentColor)
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(Prefs.homeShortcutKeys(homeShortcutsRaw), id: \.self) { k in
                            shortcut(Prefs.smartNames[k] ?? k, Prefs.smartIcons[k] ?? "tray", SidebarView.mailbox(forSmart: k))
                        }
                    }
                    .sheet(isPresented: $showingShortcutEdit) {
                        NavigationStack {
                            HomeShortcutEditView()
                                .toolbar { Button("完成") { showingShortcutEdit = false } }
                        }
                    }

                    // 账户
                    if !accounts.isEmpty {
                        Text("账户").font(.headline)
                        VStack(spacing: 0) {
                            ForEach(accounts) { a in
                                Button { openAccount(a) } label: {
                                    HStack(spacing: 12) {
                                        ProviderBadge(preset: ProviderPreset.preset(a.providerID), size: 34)
                                        Text(a.displayName.isEmpty ? a.email : a.displayName).lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                    }.padding(.vertical, 10)
                                }.buttonStyle(.plain)
                                if a.id != accounts.last?.id { Divider() }
                            }
                        }.padding(.horizontal, 4)
                    }
                    // dock 是悬浮盖在内容上面的，底部留 100pt 透明留白，最后一行才能滑到 dock 上面完整露出来，不被 dock 盖住
                    Color.clear.frame(height: 100)
                }
                .padding()
            }
            .navigationTitle("首页")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { app.showingSearch = true } label: { Image(systemName: "magnifyingglass") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { app.composeDraft = ComposeDraft(accountID: nil) } label: { Image(systemName: "square.and.pencil") }
                        .disabled(accounts.isEmpty)
                }
            }
            .onAppear { loadAvatar() }
        }
    }

    private func statCard(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .background { RoundedRectangle(cornerRadius: 16).fill(.white).overlay { RoundedRectangle(cornerRadius: 16).stroke(.black.opacity(0.06), lineWidth: 0.5) } }.shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private func shortcut(_ title: String, _ icon: String, _ mailbox: AppState.Mailbox) -> some View {
        Button {
            app.selectedMailbox = mailbox
            app.selectedMessage = nil
            app.dockTab = .mail
        } label: {
            HStack(spacing: 10) {
                // 快捷入口图标用 iOS 原生图标样式：直接放 SF 图标，不套灰色圆底，
                // 和右上角搜索图标一样干净，图标本身就是黑色的
                Image(systemName: icon).font(.body).foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                Text(title).font(.body.weight(.medium))
                Spacer()
            }.padding()
        }
        .buttonStyle(.plain)
        .background { RoundedRectangle(cornerRadius: 16).fill(.white).overlay { RoundedRectangle(cornerRadius: 16).stroke(.black.opacity(0.06), lineWidth: 0.5) } }.shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private func openAccount(_ a: Account) {
        if let f = a.folders.first(where: { $0.role == "inbox" }) {
            app.selectedMailbox = .folder(f.persistentModelID)
        } else {
            app.selectedMailbox = .unified
        }
        app.selectedMessage = nil
        app.dockTab = .mail
    }

    private func loadAvatar() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyAvatar.png")
        guard let data = try? Data(contentsOf: url) else { return }
        avatarImage = UIImage(data: data)
    }
}

/// AI：暂时不启用，现在就是个空页。
struct AIPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("AI 暂未启用", systemImage: "sparkles",
                                   description: Text("AI 功能还在准备中，这里先留空。"))
                .navigationTitle("AI")
        }
    }
}

/// 首页快捷入口编辑：已选的可拖动排序、左滑删除；未选的点“+”加进来；一键恢复默认。
struct HomeShortcutEditView: View {
    @AppStorage(Prefs.homeShortcuts) private var raw = Prefs.defaultHomeShortcuts

    private var selected: [String] { Prefs.homeShortcutKeys(raw) }
    private var unselected: [String] { Prefs.allSmart.filter { !selected.contains($0) } }

    var body: some View {
        List {
            Section("快捷入口") {
                ForEach(selected, id: \.self) { k in
                    Label(Prefs.smartNames[k] ?? k, systemImage: Prefs.smartIcons[k] ?? "tray")
                }
                .onMove { from, to in
                    var s = selected; s.move(fromOffsets: from, toOffset: to); raw = s.joined(separator: ",")
                }
                .onDelete { idx in
                    var s = selected; s.remove(atOffsets: idx); raw = s.joined(separator: ",")
                }
            }
            Section("添加功能") {
                ForEach(unselected, id: \.self) { k in
                    Button {
                        raw = (selected + [k]).joined(separator: ",")
                    } label: {
                        Label(Prefs.smartNames[k] ?? k, systemImage: Prefs.smartIcons[k] ?? "tray")
                    }
                }
            }
            Section {
                Button("恢复默认") { raw = Prefs.defaultHomeShortcuts }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("编辑快捷入口")
    }
}
