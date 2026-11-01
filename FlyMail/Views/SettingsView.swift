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
    @State private var confirmReset = false
    @State private var confirmClearAvatar = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { AISettingsView() } label: { Label("AI", systemImage: "sparkles") }
                    NavigationLink { SyncSettingsView() } label: { Label("同步", systemImage: "arrow.triangle.2.circlepath") }
                }
                Section("自定义") {
                    NavigationLink { SidebarEditView() } label: { Label("编辑侧边栏", systemImage: "sidebar.left") }
                    NavigationLink { AppearanceSettingsView() } label: { Label("外观与列表", systemImage: "paintbrush") }
                    NavigationLink { SwipeSettingsView() } label: { Label("滑动操作", systemImage: "hand.draw") }
                    Toggle(isOn: $grouping) { Label("按主题合并会话", systemImage: "bubble.left.and.bubble.right") }
                }
                Section {
                    Picker(selection: $defaultAccount) {
                        Text("第一个账户").tag("")
                        ForEach(accounts) { Text($0.email).tag($0.id.uuidString) }
                    } label: { Label("默认邮箱", systemImage: "envelope") }
                    Picker(selection: $badgeSource) {
                        Text("仅收件箱未读").tag("inbox"); Text("所有未读").tag("all"); Text("VIP 未读").tag("vip"); Text("不显示").tag("none")
                    } label: { Label("应用角标", systemImage: "app.badge") }
                    Toggle(isOn: $signatureCard) { Label("资料卡签名", systemImage: "signature") }
                }
                Section {
                    // 备份与恢复是单独独立的一页：从设置页点进去是它，
                    // 从“我的”页点进去也是它，不再是设置页里的一个 Section
                    NavigationLink { BackupRestoreView() } label: { Label("备份与恢复", systemImage: "externaldrive") }
                }
                Section {
                    Toggle(isOn: $showAvatars) { Label("显示头像", systemImage: "person.crop.circle") }
                    Toggle(isOn: $remoteAvatars) { Label("加载发件人头像", systemImage: "photo.circle") }.disabled(!showAvatars)
                    Button(role: .destructive) { confirmClearAvatar = true } label: { Label("清除头像缓存", systemImage: "trash") }
                }
                Section {
                    NavigationLink { VIPListView() } label: { HStack { Label("VIP 发件人", systemImage: "star.circle"); Spacer(); Text("\(VIPStore.list.count)").foregroundStyle(.secondary) } }
                    NavigationLink { SpamSettingsView() } label: { Label("垃圾邮件", systemImage: "xmark.bin") }
                }
                Section {
                    Button(role: .destructive) { confirmReset = true } label: { Label("还原设置", systemImage: "arrow.counterclockwise") }
                } footer: {
                    // 还原设置按钮下面一行功能提示：点之前就知道它是干嘛的，不用点进确认框才看到
                    Text("将侧边栏、外观、滑动等自定义还原为默认，不影响账户和 VIP。")
                }
            }
            .navigationTitle("设置")
            .toolbar { Button("完成") { dismiss() } }
            .alert("还原设置？", isPresented: $confirmReset) {
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
    @Environment(\.editMode) private var editMode
    var body: some View {
        let list = VIPStore.list
        List {
            if list.isEmpty { Text("在邮件详情或长按邮件选择“设为 VIP”").foregroundStyle(.secondary) }
            ForEach(list, id: \.self) { Text($0) }
                .onDelete { idx in idx.map { list[$0] }.forEach(VIPStore.remove) }
        }
        .navigationTitle("VIP")
        .toolbar {
            Button(editMode == .active ? "完成" : "编辑") {
                editMode?.wrappedValue = editMode == .active ? .inactive : .active
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

/// AI 设置统一入口：模型列表、主备调用顺序和个性化指令都集中在这里。
struct AISettingsView: View {
    @State private var profiles = AIModelStore.loadProfiles()
    @State private var primaryID = AIModelStore.primaryProfileID
    @State private var editorRequest: AIModelEditorRequest?
    @State private var pendingDeleteID: String?
    @State private var confirmDelete = false
    @State private var isEditing = false
    @AppStorage("ai.translationProfileID") private var translationProfileID = ""
    @AppStorage(AIPersonalization.enterToSendKey) private var enterToSend = false
    @AppStorage(AIMemoryStore.enabledKey) private var memoryEnabled = true
    @AppStorage(AIPersonalization.nameKey) private var assistantName = "FlyMail 助手"
    @AppStorage(AIPersonalization.languageKey) private var responseLanguage = "auto"
    @AppStorage(AIPersonalization.toneKey) private var responseTone = "natural"
    @AppStorage(AIPersonalization.instructionKey) private var customInstruction = ""

    var body: some View {
        List {
            Section {
                if profiles.isEmpty {
                    ContentUnavailableView(
                        "还没有模型",
                        systemImage: "cpu",
                        description: Text("添加一个或多个模型。首选模型失败时，可以自动尝试已启用的备用模型。")
                    )
                    .listRowBackground(Color.clear)
                }

                ForEach(profiles) { profile in
                    modelRow(profile)
                }
                .onMove { source, destination in
                    profiles.move(fromOffsets: source, toOffset: destination)
                    AIModelStore.saveProfiles(profiles)
                }

                Button {
                    editorRequest = AIModelEditorRequest(profile: AIModelProfile.makeDefault(), isNew: true)
                } label: {
                    Label("添加模型", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("模型配置")
            } footer: {
                Text("每个模型独立保存服务商、API 地址、模型名称和 API Key。可以添加多个配置，并在模型列表中拖动调整备用模型的尝试顺序。")
            }

            Section {
                if profiles.isEmpty {
                    Text("添加模型后即可选择首选和备用模型。")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("首选模型", selection: $primaryID) {
                        ForEach(profiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }

                    ForEach(profiles.filter { $0.id != primaryID }) { profile in
                        Toggle(isOn: Binding(
                            get: { profile.isFallback },
                            set: { setFallback(profile.id, enabled: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                Text(profile.model).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("主模型与回退")
            } footer: {
                Text("先请求首选模型；失败、超时或返回错误时，按模型列表顺序尝试开启的备用模型。没有勾选为备用的模型不会被自动调用。")
            }

            Section {
                TextField("助手名称", text: $assistantName)
                Picker("回复语言", selection: $responseLanguage) {
                    Text("跟随提问语言").tag("auto")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }
                Picker("回复风格", selection: $responseTone) {
                    Text("自然均衡").tag("natural")
                    Text("简洁直接").tag("concise")
                    Text("专业严谨").tag("professional")
                    Text("友好耐心").tag("friendly")
                    Text("详细解释").tag("detailed")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("自定义个性化指令")
                        .font(.subheadline.weight(.medium))
                    TextEditor(text: $customInstruction)
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    Text("例如：希望 AI 扮演什么角色、回答时遵守哪些习惯、哪些内容需要优先关注。此指令会应用到 AI 聊天和邮件 AI 功能。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("AI 个性化")
            } footer: {
                Text("这些设置保存在本机，并自动附加到每次 AI 请求中，不会覆盖邮件原文。")
            }

            Section {
                Picker("默认翻译模型", selection: $translationProfileID) {
                    Text("跟随首选模型").tag("")
                    ForEach(profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
            } header: {
                Text("翻译")
            } footer: {
                Text("翻译功能会优先使用这里指定的模型；留空时跟随首选模型。摘要、润色和其他邮件 AI 功能默认使用首选模型。")
            }

            Section {
                Toggle("回车键发送", isOn: $enterToSend)
            } header: {
                Text("聊天体验")
            } footer: {
                Text("默认关闭。关闭时回车用于换行；开启后按回车直接发送，仍可使用发送按钮。")
            }

            Section {
                Toggle("自动整理长期记忆", isOn: $memoryEnabled)

                HStack(spacing: 10) {
                    Image(systemName: memoryEnabled ? "sparkles.rectangle.stack" : "pause.circle")
                        .font(.title2)
                        .foregroundStyle(memoryEnabled ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(memoryEnabled ? "自动整理已开启" : "自动整理已暂停")
                            .font(.subheadline.weight(.semibold))
                        Text(memoryEnabled
                             ? "对话积累约 20 条消息后自动提炼；之后保留最近 8 条原文作为上下文。完整历史仍可在侧栏查看。"
                             : "关闭后会停止自动提炼，并继续发送完整对话上下文。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 5)

                if AIMemoryStore.hasMemories {
                    Text("已为部分对话整理记忆。每条对话的记忆相互隔离，仅用于同一条对话的后续请求。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("目前还没有整理出的长期记忆。整理过程在后台完成，不会弹出打断对话的窗口。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("清空长期记忆", role: .destructive) {
                    AIMemoryStore.clear()
                }
            } header: {
                Text("AI 记忆")
            } footer: {
                Text("开启后，FlyMail 会自动压缩较早对话、提炼稳定偏好和重要信息；摘要保存在本机，并用于后续对话。压缩后请求只携带最近 8 条原始消息，可减少重复上下文和 Token 消耗。整理时调用当前首选模型，可能产生少量 API 用量。")
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .navigationTitle("AI 设置")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(isEditing ? "完成" : "编辑") { isEditing.toggle() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorRequest = AIModelEditorRequest(profile: AIModelProfile.makeDefault(), isNew: true)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加模型")
            }
        }
        .onAppear {
            reload()
        }
        .onChange(of: primaryID) { _, newValue in
            AIModelStore.setPrimaryProfileID(newValue)
        }
        .onChange(of: translationProfileID) { _, newValue in
            AIModelStore.setTranslationProfileID(newValue)
        }
        .sheet(item: $editorRequest) { request in
            NavigationStack {
                AIModelEditorView(profile: request.profile, isNew: request.isNew) { saved in
                    if let index = profiles.firstIndex(where: { $0.id == saved.id }) {
                        profiles[index] = saved
                    } else {
                        profiles.append(saved)
                    }
                    AIModelStore.saveProfiles(profiles)
                    if primaryID.isEmpty { primaryID = saved.id }
                }
            }
        }
        .confirmationDialog(
            "删除模型配置？",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { deletePendingProfile() }
            Button("取消", role: .cancel) { pendingDeleteID = nil }
        } message: {
            Text("该模型的本地配置和对应 API Key 都会被删除。")
        }
    }

    @ViewBuilder
    private func modelRow(_ profile: AIModelProfile) -> some View {
        let configured = !(KeychainStore.get(AIModelStore.keychainKey(for: profile.id)) ?? "").isEmpty
        HStack(spacing: 10) {
            Button {
                editorRequest = AIModelEditorRequest(profile: profile, isNew: false)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.name).font(.body.weight(.semibold)).foregroundColor(.primary)
                    Text("\(profile.providerRaw) · \(profile.model)")
                        .font(.footnote).foregroundColor(.secondary).lineLimit(1)
                    Text(configured ? "API Key 已保存" : "尚未设置 API Key")
                        .font(.caption2)
                        .foregroundColor(configured ? Color.secondary : Color.orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .trailing, spacing: 5) {
                if profile.id == primaryID {
                    Text("首选").font(.caption2.weight(.semibold)).foregroundColor(.cyan)
                }
                if profile.isFallback && profile.id != primaryID {
                    Text("备用").font(.caption2).foregroundColor(.secondary)
                }
            }

            Menu {
                if profile.id != primaryID {
                    Button("设为首选", systemImage: "star") { primaryID = profile.id }
                }
                Button(
                    profile.isFallback ? "取消备用" : "设为备用",
                    systemImage: profile.isFallback ? "minus.circle" : "arrow.uturn.backward"
                ) {
                    setFallback(profile.id, enabled: !profile.isFallback)
                }
                Button("编辑", systemImage: "pencil") {
                    editorRequest = AIModelEditorRequest(profile: profile, isNew: false)
                }
                Button("删除", systemImage: "trash", role: .destructive) {
                    pendingDeleteID = profile.id
                    confirmDelete = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
            }
        }
        .padding(.vertical, 3)
    }

    private func reload() {
        profiles = AIModelStore.loadProfiles()
        let savedPrimary = AIModelStore.primaryProfileID
        if profiles.contains(where: { $0.id == savedPrimary }) {
            primaryID = savedPrimary
        } else {
            primaryID = profiles.first?.id ?? ""
        }
        AIModelStore.setPrimaryProfileID(primaryID)
    }

    private func setFallback(_ id: String, enabled: Bool) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].isFallback = enabled
        AIModelStore.saveProfiles(profiles)
    }

    private func deletePendingProfile() {
        guard let id = pendingDeleteID else { return }
        KeychainStore.delete(AIModelStore.keychainKey(for: id))
        profiles.removeAll { $0.id == id }
        AIModelStore.saveProfiles(profiles)
        if primaryID == id {
            primaryID = profiles.first?.id ?? ""
        }
        AIModelStore.setPrimaryProfileID(primaryID)
        pendingDeleteID = nil
    }
}

private struct AIModelEditorRequest: Identifiable {
    let profile: AIModelProfile
    let isNew: Bool
    var id: String { profile.id }
}

private struct AIModelEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AIModelProfile
    @State private var apiKey = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var testError = false

    let isNew: Bool
    let onSave: (AIModelProfile) -> Void

    init(profile: AIModelProfile, isNew: Bool, onSave: @escaping (AIModelProfile) -> Void) {
        _draft = State(initialValue: profile)
        self.isNew = isNew
        self.onSave = onSave
    }

    private var savedKeyExists: Bool {
        !(KeychainStore.get(AIModelStore.keychainKey(for: draft.id)) ?? "").isEmpty
    }

    private var effectiveKey: String {
        let entered = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return entered.isEmpty
            ? (KeychainStore.get(AIModelStore.keychainKey(for: draft.id)) ?? "")
            : entered
    }

    var body: some View {
        Form {
            Section {
                TextField("配置名称", text: $draft.name)
                Picker("服务商", selection: $draft.providerRaw) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider.rawValue)
                    }
                }
                TextField("API Base URL", text: $draft.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("模型名称", text: $draft.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if FlyMailAI.canControlReasoning(draft) {
                    Picker("默认思考等级", selection: $draft.reasoningDefaultRaw) {
                        ForEach(FlyMailAI.reasoningOptions(for: draft)) { level in
                            Text(FlyMailAI.reasoningTitle(level, for: draft)).tag(level.rawValue)
                        }
                    }
                    Text("新配置默认关闭思考。部分型号不支持彻底关闭，选择关闭时会使用该型号官方允许的最低档位。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("该模型不支持通过此 API 单独调整思考等级", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if draft.provider == .zhipu && draft.model.lowercased().contains("glm-5.3") {
                    Text("GLM-5.3 强制启用思考；选择“关闭”时会自动使用最低思考强度。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if draft.provider == .gemini && draft.model.lowercased().contains("2.5") && draft.model.lowercased().contains("pro") {
                    Text("Gemini 2.5 Pro 不支持完全关闭思考；关闭选项会使用最低可用预算。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("基本信息")
            } footer: {
                Text("请填写服务商提供的兼容 API 根地址和模型 ID。Claude 使用 Anthropic Messages API，其余服务商使用 Chat Completions API。")
            }

            Section {
                SecureField(savedKeyExists ? "已保存密钥，留空则不修改" : "粘贴 API Key", text: $apiKey)
                if savedKeyExists {
                    Label("已有 API Key 保存在 iOS 钥匙串", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("API Key")
            } footer: {
                Text("每个模型单独保存密钥。密钥仅保存在本机钥匙串中，只有发起 AI 请求时才发送给对应服务商。")
            }

            Section {
                Button {
                    runConnectionTest()
                } label: {
                    HStack {
                        Text("测试连接")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(testing || effectiveKey.isEmpty || draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let testResult {
                    Text(testResult)
                        .font(.footnote)
                        .foregroundStyle(testError ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(isNew ? "添加模型" : "编辑模型")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(
                        draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        effectiveKey.isEmpty
                    )
            }
        }
        .onChange(of: draft.providerRaw) { _, value in
            let provider = AIProvider(rawValue: value) ?? .custom
            draft.name = provider.rawValue
            draft.baseURL = provider.baseURL
            draft.model = provider.defaultModel
            testResult = nil
        }
    }

    private func save() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            KeychainStore.set(key, for: AIModelStore.keychainKey(for: draft.id))
        }
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.name = draft.providerRaw
        }
        onSave(draft)
        dismiss()
    }

    private func runConnectionTest() {
        testing = true
        testResult = nil
        let profile = draft
        let key = effectiveKey
        Task {
            do {
                _ = try await FlyMailAI.chat(
                    profile: profile,
                    apiKey: key,
                    messages: [AIChatMessage(role: "user", content: "请仅回复：连接成功")]
                )
                await MainActor.run {
                    testResult = "连接成功，模型已正常响应。"
                    testError = false
                    testing = false
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    testResult = message
                    testError = true
                    testing = false
                }
            }
        }
    }
}
