import SwiftUI
import SwiftData
import UserNotifications

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.createdAt) private var accounts: [Account]

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    static var appBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1" }
    @AppStorage(Prefs.showAvatars) private var showAvatars = true
    @AppStorage(Prefs.remoteAvatars) private var remoteAvatars = true
    @AppStorage(Prefs.defaultAccount) private var defaultAccount = ""
    @AppStorage(Prefs.badgeSource) private var badgeSource = "inbox"
    @AppStorage(Prefs.grouping) private var grouping = false
    @AppStorage(Prefs.mySignatureCard) private var signatureCard = true
    @AppStorage(Prefs.vipList) private var vipRaw = ""
    @AppStorage("app.language") private var appLanguage = ""
    @State private var confirmReset = false
    @State private var confirmClearAvatar = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { SyncSettingsView() } label: { Label(L10n.t("同步"), systemImage: "arrow.triangle.2.circlepath") }
                }
                Section {
                    Picker(selection: $appLanguage) {
                        Text(L10n.t("跟随系统")).tag("")
                        Text("简体中文").tag("zh-Hans")
                        Text("繁體中文").tag("zh-Hant")
                        Text("English").tag("en")
                        Text("日本語").tag("ja")
                    } label: { Label(L10n.t("语言"), systemImage: "globe") }
                } header: {
                    Text(L10n.t("通用"))
                } footer: {
                    Text(L10n.t("默认跟随系统语言，可手动固定。切换后日期、系统菜单等会立即跟随所选语言；应用内文案正在逐步适配以上语言。"))
                }
                Section(L10n.t("自定义")) {
                    NavigationLink { SidebarEditView() } label: { Label(L10n.t("编辑侧边栏"), systemImage: "sidebar.left") }
                    NavigationLink { AppearanceSettingsView() } label: { Label(L10n.t("外观与列表"), systemImage: "paintbrush") }
                    NavigationLink { SwipeSettingsView() } label: { Label(L10n.t("滑动操作"), systemImage: "hand.draw") }
                    Toggle(isOn: $grouping) { Label(L10n.t("按主题合并会话"), systemImage: "bubble.left.and.bubble.right") }
                }
                Section {
                    Picker(selection: $defaultAccount) {
                        Text(L10n.t("第一个账户")).tag("")
                        ForEach(accounts) { Text($0.email).tag($0.id.uuidString) }
                    } label: { Label(L10n.t("默认邮箱"), systemImage: "envelope") }
                    Picker(selection: $badgeSource) {
                        Text(L10n.t("仅收件箱未读")).tag("inbox"); Text(L10n.t("所有未读")).tag("all"); Text(L10n.t("VIP 未读")).tag("vip"); Text(L10n.t("不显示")).tag("none")
                    } label: { Label(L10n.t("应用角标"), systemImage: "app.badge") }
                    Toggle(isOn: $signatureCard) { Label(L10n.t("资料卡签名"), systemImage: "signature") }
                }
                Section {
                    // 备份与恢复是单独独立的一页：从设置页点进去是它，
                    // 从“我的”页点进去也是它，不再是设置页里的一个 Section
                    NavigationLink { BackupRestoreView() } label: { Label(L10n.t("备份与恢复"), systemImage: "externaldrive") }
                }
                Section {
                    Toggle(isOn: $showAvatars) { Label(L10n.t("显示头像"), systemImage: "person.crop.circle") }
                    Toggle(isOn: $remoteAvatars) { Label(L10n.t("加载发件人头像"), systemImage: "photo.circle") }.disabled(!showAvatars)
                    Button(role: .destructive) { confirmClearAvatar = true } label: { Label(L10n.t("清除头像缓存"), systemImage: "trash") }
                }
                Section {
                    NavigationLink { VIPListView() } label: { HStack { Label(L10n.t("VIP 发件人"), systemImage: "star.circle"); Spacer(); Text("\(VIPStore.list.count)").foregroundStyle(.secondary) } }
                    NavigationLink { SpamSettingsView() } label: { Label(L10n.t("垃圾邮件"), systemImage: "xmark.bin") }
                }
                Section {
                    Button(role: .destructive) { confirmReset = true } label: { Label(L10n.t("还原设置"), systemImage: "arrow.counterclockwise") }
                } footer: {
                    // 还原设置按钮下面一行功能提示：点之前就知道它是干嘛的，不用点进确认框才看到
                    Text(L10n.t("将侧边栏、外观、滑动等自定义还原为默认，不影响账户和 VIP。"))
                }
            }
            .navigationTitle(L10n.t("设置"))
            .toolbar { Button(L10n.t("完成")) { dismiss() } }
            .alert(L10n.t("还原设置？"), isPresented: $confirmReset) {
                Button("还原", role: .destructive) {
                    Prefs.resetAll()
                    for a in accounts { a.sortIndex = 0; a.colorIndex = 0; a.collapsedRoles = ["inbox", "sent"]; a.hiddenFolders = []
                        for f in a.folders { f.sortIndex = -1 } }
                    Task { await AvatarService.shared.clearCache() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("把侧边栏、外观、滑动等自定义还原为默认，不影响账户和 VIP。")
            }
            // 清除头像缓存和其他删除/恢复一样：先弹居中确认框一次，确认后才清，不点一下就直接清掉
            .alert("清除头像缓存？", isPresented: $confirmClearAvatar) {
                Button("清除", role: .destructive) {
                    Task { await AvatarService.shared.clearCache() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将清除已缓存的头像，之后打开邮件时会重新加载，不影响账户和邮件。")
            }
        }
    }
}

struct SyncSettingsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(Prefs.syncRangeDays) private var rangeDays = 30
    @AppStorage(Prefs.syncInterval) private var interval = 0
    @AppStorage(Prefs.autoBody) private var autoBody = "all"
    @AppStorage(Prefs.autoAttach) private var autoAttach = "5"
    @State private var downloading = false
    @State private var downloadResult: String?
    var body: some View {
        Form {
            // 自动同步：就是一个普通开关，和系统设置里一样。开 = 实时推送，
            // 关 = 手动（-1），不用再去“更新频率”里猜 -1 是不是关闭。
            Section {
                Toggle("自动同步", isOn: Binding(
                    get: { interval != -1 },
                    set: { on in interval = on ? 0 : -1 }
                ))
            } header: { Text("自动同步") } footer: {
                Text(interval == -1
                     ? "现在是关闭状态：只在你下拉刷新或点“立即自动下载”时才同步。"
                     : "现在是开启状态：按下方“更新频率”自动同步，App 在后台时由 iOS 决定唤醒时机。")
            }
            Section {
                Button {
                    downloading = true; downloadResult = nil
                    Task {
                        let svc = MailSyncService(modelContainer: context.container)
                        _ = await svc.syncAll()
                        await svc.prefetchBodies(onWiFi: true, maxCount: 200)
                        downloading = false
                        downloadResult = "已同步并预取正文，打开邮件可直接读本地缓存，不用现拉。"
                    }
                } label: {
                    HStack { Text("立即自动下载全部收件箱邮件"); Spacer(); if downloading { ProgressView() } }
                }.disabled(downloading)
                if let downloadResult { Text(downloadResult).font(.callout).foregroundStyle(.secondary) }
            } header: { Text("自动下载") } footer: { Text("平时同步后会自动预取正文（见下方“离线下载”）；点上面这个按钮就是现在立刻把全部收件箱的正文拉下来，之后打开邮件就快了。") }
            Section {
                Picker("一次拉取邮件范围", selection: $rangeDays) { ForEach(Prefs.rangeOptions, id: \.0) { Text($0.1).tag($0.0) } }
            } footer: { Text("按日期在服务器上筛选（IMAP SEARCH SINCE），每个文件夹单次最多 3000 封。扩大范围后下次同步会补齐更早的邮件；更早的邮件可用全局搜索从服务器查找。") }
            Section {
                Picker("更新频率", selection: $interval) { ForEach(Prefs.intervalOptions, id: \.0) { Text($0.1).tag($0.0) } }
            } footer: { Text("仅在 App 打开时生效。“实时推送”使用 IMAP IDLE 保持连接；App 在后台时由 iOS 决定何时唤醒刷新，无法保证固定频率。") }
            Section {
                Picker("自动下载正文", selection: $autoBody) { Text("全部").tag("all"); Text("仅 Wi-Fi").tag("wifi"); Text("关闭").tag("off") }
                Picker("自动下载附件", selection: $autoAttach) {
                    Text("关闭").tag("off"); Text("小于 1 MB").tag("1"); Text("小于 5 MB").tag("5"); Text("小于 20 MB").tag("20"); Text("仅 Wi-Fi").tag("wifi")
                }
            } header: { Text("离线下载") } footer: { Text("同步后在后台按从新到旧预取正文（最多 4 个并发连接）。预取只拉文本部分，不拉附件，所以带大附件的邮件打开也快；附件在点开时再单独下载。") }
        }
        .navigationTitle("同步")
    }
}

struct VIPListView: View {
    @AppStorage(Prefs.vipList) private var vipRaw = ""
    @Environment(\.editMode) private var editMode: Binding<EditMode>?
    var body: some View {
        let list = VIPStore.list
        List {
            if list.isEmpty { Text("在邮件详情或长按邮件选择“设为 VIP”").foregroundStyle(.secondary) }
            ForEach(list, id: \.self) { Text($0) }
                .onDelete { idx in idx.map { list[$0] }.forEach(VIPStore.remove) }
        }
        .navigationTitle("VIP")
        .toolbar {
            Button(editMode?.wrappedValue == .active ? "完成" : "编辑") {
                editMode?.wrappedValue = editMode?.wrappedValue == .active ? .inactive : .active
            }
        }
    }
}

struct AppearanceSettingsView: View {
    @AppStorage(Prefs.density) private var density = 1
    @AppStorage(Prefs.previewLines) private var previewLines = 2
    @AppStorage(Prefs.accent) private var accent = 0
    var body: some View {
        Form {
            Picker("列表密度", selection: $density) { Text("紧凑").tag(0); Text("标准").tag(1); Text("宽松").tag(2) }.pickerStyle(.segmented)
            Stepper("预览行数：\(previewLines)", value: $previewLines, in: 0...3)
            Section("强调色") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 12) {
                    ForEach(Prefs.palette.indices, id: \.self) { i in
                        Circle().fill(Prefs.palette[i]).frame(width: 30, height: 30)
                            .overlay { if i == accent { Image(systemName: "checkmark").foregroundStyle(.white).font(.caption.bold()) } }
                            .onTapGesture { accent = i }
                            .accessibilityLabel(Prefs.paletteNames[i])
                    }
                }.padding(.vertical, 4)
            }
        }
        .navigationTitle("外观与列表")
    }
}

struct SwipeSettingsView: View {
    @AppStorage(Prefs.leading1) private var leading1 = "read"
    @AppStorage(Prefs.leading2) private var leading2 = "flag"
    @AppStorage(Prefs.trailing1) private var trailing1 = "delete"
    @AppStorage(Prefs.trailing2) private var trailing2 = "archive"
    var body: some View {
        Form {
            Section("向右滑（左侧）") { picker("第一个", $leading1); picker("第二个", $leading2) }
            Section { picker("第一个", $trailing1); picker("第二个", $trailing2) } header: { Text("向左滑（右侧）") }
        }
        .navigationTitle("滑动操作")
    }
    private func picker(_ t: String, _ b: Binding<String>) -> some View {
        Picker(t, selection: b) { ForEach(Prefs.swipeActions, id: \.self) { Text(Prefs.swipeNames[$0] ?? $0).tag($0) } }
    }
}

struct SidebarEditView: View {
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Environment(\.modelContext) private var context
    @AppStorage(Prefs.smartOrder) private var smartOrder = Prefs.defaultSmartOrder
    @AppStorage(Prefs.smartHidden) private var smartHidden = ""

    private var sorted: [Account] { accounts.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) } }

    var body: some View {
        let order = Prefs.orderedSmart(smartOrder)
        let hidden = Set(smartHidden.split(separator: ",").map(String.init))
        List {
            Section { 
                ForEach(order, id: \.self) { k in
                    Toggle(isOn: Binding(get: { !hidden.contains(k) }, set: { on in
                        var h = hidden; if on { h.remove(k) } else { h.insert(k) }
                        smartHidden = h.sorted().joined(separator: ",")
                    })) { Label(Prefs.smartNames[k] ?? k, systemImage: Prefs.smartIcons[k] ?? "tray") }
                }
                .onMove { from, to in
                    var o = order; o.move(fromOffsets: from, toOffset: to); smartOrder = o.joined(separator: ",")
                }
            } header: { Text("智能邮箱") }
            Section("账户") {
                ForEach(sorted) { a in
                    NavigationLink { AccountSidebarEditView(account: a) } label: {
                        HStack {
                            Circle().fill(Prefs.palette[a.colorIndex % Prefs.palette.count]).frame(width: 10, height: 10)
                            Text(a.displayName.isEmpty ? a.email : a.displayName)
                        }
                    }
                }
                .onMove { from, to in
                    var l = sorted; l.move(fromOffsets: from, toOffset: to)
                    for (i, a) in l.enumerated() { a.sortIndex = i }
                    try? context.save()
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("编辑侧边栏")
    }
}

struct AccountSidebarEditView: View {
    @Bindable var account: Account
    @Environment(\.modelContext) private var context
    @State private var folders: [MailFolder] = []

    var body: some View {
        List {
            Section("显示") {
                TextField("显示名称", text: $account.displayName)
                Picker("颜色标签", selection: $account.colorIndex) {
                    ForEach(Prefs.palette.indices, id: \.self) { i in
                        Label(Prefs.paletteNames[i], systemImage: "circle.fill").foregroundStyle(Prefs.palette[i]).tag(i)
                    }
                }
            }
            Section { 
                ForEach(SidebarView.roleOrder, id: \.self) { r in
                    Toggle(SidebarView.roleNames[r] ?? r, isOn: Binding(get: { account.collapsedRoles.contains(r) }, set: { on in
                        if on { if !account.collapsedRoles.contains(r) { account.collapsedRoles.append(r) } }
                        else { account.collapsedRoles.removeAll { $0 == r } }
                    }))
                }
            } header: { Text("折叠时显示") }
            Section { 
                ForEach(folders) { f in
                    Toggle(isOn: Binding(get: { !account.hiddenFolders.contains(f.path) }, set: { on in
                        if on { account.hiddenFolders.removeAll { $0 == f.path } } else { account.hiddenFolders.append(f.path) }
                    })) { Label(SidebarView.folderName(f), systemImage: SidebarView.roleIcons[f.role] ?? "folder") }
                }
                .onMove { from, to in
                    folders.move(fromOffsets: from, toOffset: to)
                    for (i, f) in folders.enumerated() { f.sortIndex = i }
                }
            } header: { Text("文件夹") }
            Section {
                Button("恢复此账户默认") {
                    account.collapsedRoles = ["inbox", "sent"]; account.hiddenFolders = []
                    for f in account.folders { f.sortIndex = -1 }
                    folders = SidebarView.orderedFolders(account)
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(account.email)
        .onAppear { folders = SidebarView.orderedFolders(account) }
        .onDisappear { try? context.save() }
    }
}

struct SpamSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SpamFilter.autoMoveKey) private var autoMove = false
    @AppStorage(SpamFilter.thresholdKey) private var threshold = 50
    @State private var block = SpamFilter.blockList
    @State private var allow = SpamFilter.allowList
    @State private var newEntry = ""
    @State private var toBlock = true

    var body: some View {
            Form {
                Section {
                    Toggle("自动移入垃圾邮件", isOn: $autoMove)
                    Stepper("判定阈值：\(threshold) 分", value: $threshold, in: 20...150, step: 10)
                } header: { Text("垃圾邮件识别") }
                Section("添加规则") {
                    TextField("邮箱地址或域名，如 spam.com", text: $newEntry).textInputAutocapitalization(.never).keyboardType(.emailAddress)
                    Picker("加入", selection: $toBlock) { Text("黑名单").tag(true); Text("白名单").tag(false) }.pickerStyle(.segmented)
                    Button("添加") { SpamFilter.add(newEntry, toBlock: toBlock); newEntry = ""; reload() }.disabled(newEntry.isEmpty)
                }
                Section("黑名单（\(block.count)）") {
                    ForEach(block, id: \.self) { Text($0) }
                        .onDelete { idx in idx.forEach { SpamFilter.remove(block[$0], fromBlock: true) }; reload() }
                }
                Section("白名单（\(allow.count)）") {
                    ForEach(allow, id: \.self) { Text($0) }
                        .onDelete { idx in idx.forEach { SpamFilter.remove(allow[$0], fromBlock: false) }; reload() }
                }
            }
            .navigationTitle("垃圾邮件")
    }

    private func reload() { block = SpamFilter.blockList; allow = SpamFilter.allowList }
}
