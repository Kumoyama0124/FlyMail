import SwiftUI
import SwiftData

/// 服务商图标：自绘字标徽章，联网时尝试换成站点图标
struct ProviderBadge: View {
    let preset: ProviderPreset
    var size: CGFloat = 36
    @AppStorage(Prefs.remoteAvatars) private var remote = true
    @State private var image: UIImage?

    var body: some View {
        let t = preset.tint
        ZStack {
            if let image {
                Color.white
                // 100% 铺满：不再 scaledToFit + 内边距留白，直接拉伸到整个圆角框，
                // 再由外层 clipShape 裁成圆角矩形，图标本身不被裁掉、也不留白边。
                Image(uiImage: image).resizable().interpolation(.high).frame(width: size, height: size)
            } else {
                LinearGradient(colors: [Color(red: t.0, green: t.1, blue: t.2), Color(red: t.0 * 0.75, green: t.1 * 0.75, blue: t.2 * 0.75)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if preset.id == "icloud" { Image(systemName: "icloud.fill").font(.system(size: size * 0.45)).foregroundStyle(.white) }
                else if preset.id == "custom" { Image(systemName: "server.rack").font(.system(size: size * 0.42)).foregroundStyle(.white) }
                else {
                    Text(preset.monogram).font(.system(size: size * (preset.monogram.count > 1 ? 0.32 : 0.48), weight: .bold, design: .rounded))
                        .foregroundStyle(.white).minimumScaleFactor(0.5)
                }
            }
        }
        .frame(width: size, height: size)
        // 尽量用圆形图标：服务商徽章也改成圆的，和头像、品牌图标统一
        .clipShape(Circle())
        .overlay(Circle().stroke(.quaternary, lineWidth: 0.5))
        .task(id: preset.id) {
            guard remote, !preset.iconDomain.isEmpty else { return }
            image = await AvatarService.shared.image(for: "@" + preset.iconDomain)
        }
    }
}

/// 第一步：选择服务商
struct ProviderPickerView: View {
    @Binding var selected: ProviderPreset?
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(ProviderPreset.all) { p in
                    Button { selected = p } label: {
                        HStack(spacing: 10) {
                            ProviderBadge(preset: p, size: 34)
                            Text(p.name).font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                            if selected?.id == p.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(selected?.id == p.id ? Color.accentColor : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }
}

/// 账户管理：只按平台分组（“按分组”已去掉）
struct AccountsView: View {
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @State private var editing: Account?
    @State private var adding = false
    @State private var pendingDelete: Account?
    @State private var confirmDelete = false
    @State private var editMode: EditMode = .inactive
    @State private var selectedIDs: Set<UUID> = []
    @State private var confirmBatchDelete = false
    private var status: AccountStatus { AccountStatus.shared }

    private var groups: [(String, [Account])] {
        let sorted = accounts.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
        var order: [String] = [], map: [String: [Account]] = [:]
        for a in sorted {
            let k = a.providerID
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(a)
        }
        return order.map { ($0, map[$0]!) }
    }

    var body: some View {
        Group {
            if accounts.isEmpty {
                // 没账户时：添加账户按钮放中间，一眼就能看到，不用在列表里找
                VStack {
                    Spacer()
                    Button { adding = true } label: {
                        Label("添加账户", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 有账户时：列表里不再放一整行添加按钮，右上角一个加号就够了，简洁
                List {
                    ForEach(groups, id: \.0) { key, list in
                        Section {
                            ForEach(list) { a in row(a) }
                                .onMove { source, destination in moveAccounts(groupKey: key, groupList: list, source: source, destination: destination) }
                        } header: {
                            HStack(spacing: 8) {
                                ProviderBadge(preset: ProviderPreset.preset(key), size: 20)
                                Text(ProviderPreset.preset(key).name)
                                Text("\(list.count)").foregroundStyle(.secondary)
                            }
                            .font(.subheadline.weight(.semibold)).textCase(nil)
                        }
                    }
                }
                .environment(\.editMode, $editMode)
                // dock 是悬浮盖在内容上面的，底部安全区再加 100pt，最后一行才能滑到 dock 上面完整露出来，不被 dock 盖住
                .safeAreaPadding(.bottom, 100)
                .safeAreaInset(edge: .bottom) {
                    if editMode == .active {
                        Button { confirmBatchDelete = true } label: {
                            Text("删除（\(selectedIDs.count)）")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(selectedIDs.isEmpty)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color(.systemBackground))
                    }
                }
            }
        }
        .navigationTitle("账户")
        .toolbar {
            if !accounts.isEmpty {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(editMode == .active ? "完成" : "编辑") {
                        if editMode == .active {
                            editMode = .inactive
                            selectedIDs.removeAll()
                        } else {
                            selectedIDs.removeAll()
                            editMode = .active
                        }
                    }
                    if editMode != .active {
                        Button { adding = true } label: { Image(systemName: "plus") }
                    }
                }
            }
        }
        .alert("删除选中的账户？", isPresented: $confirmBatchDelete) {
            Button("删除", role: .destructive) {
                for id in selectedIDs {
                    if let a = accounts.first(where: { $0.id == id }) {
                        KeychainStore.deleteAll(accountID: a.id)
                        context.delete(a)
                    }
                }
                try? context.save()
                selectedIDs.removeAll()
                editMode = .inactive
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除选中的 \(selectedIDs.count) 个账户及本地缓存，不会删除服务器上的邮件。")
        }
        .alert("删除该账户？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                if let a = pendingDelete {
                    KeychainStore.deleteAll(accountID: a.id)
                    context.delete(a)
                    try? context.save()
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("删除该账户及本地缓存，此操作不会删除服务器上的邮件。")
        }
        .sheet(item: $editing) { AccountEditView(account: $0) }
        .sheet(isPresented: $adding) { AccountSetupView() }
    }

    private func row(_ a: Account) -> some View {
        let p = ProviderPreset.preset(a.providerID)
        // 整行可点进编辑（不只是右边的铅笔）：里面可改显示名称、密码/授权码、
        // IMAP/SMTP、签名、别名、分组等；图标 + 服务商名 + 邮箱地址一行显示。
        // 编辑模式下点行是选中/取消选中，不进编辑页；左边的圆圈就是选中状态。
        return Button {
            if editMode == .active {
                if selectedIDs.contains(a.id) { selectedIDs.remove(a.id) } else { selectedIDs.insert(a.id) }
            } else {
                editing = a
            }
        } label: {
            HStack(spacing: 12) {
                if editMode == .active {
                    Image(systemName: selectedIDs.contains(a.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selectedIDs.contains(a.id) ? Color.accentColor : .secondary)
                }
                ProviderBadge(preset: p, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(a.email).font(.body.weight(.medium)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(p.name).font(.caption).foregroundStyle(.secondary)
                        statusPill(a)
                    }
                }
                Spacer()
                if editMode != .active {
                    Image(systemName: "pencil.circle").font(.title3).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if editMode != .active {
                Button(role: .destructive) {
                    pendingDelete = a
                    confirmDelete = true
                } label: { Label("删除", systemImage: "trash") }
            }
        }
        .opacity(a.isEnabled ? 1 : 0.5)
    }

    private func moveAccounts(groupKey: String, groupList: [Account], source: IndexSet, destination: Int) {
        // 组内拖动排序：先把组内顺序调好，再把组内新顺序放回全局顺序里原来属于这组的位置上，
        // 其他组的相对位置不动，最后按全局新顺序重排 sortIndex 并保存。
        var newGroup = groupList
        newGroup.move(fromOffsets: source, toOffset: destination)
        let globalSorted = accounts.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
        var groupIndex = 0
        var newGlobal: [Account] = []
        for a in globalSorted {
            if a.providerID == groupKey {
                newGlobal.append(newGroup[groupIndex])
                groupIndex += 1
            } else {
                newGlobal.append(a)
            }
        }
        for (i, a) in newGlobal.enumerated() { a.sortIndex = i }
        try? context.save()
    }

    @ViewBuilder private func statusPill(_ a: Account) -> some View {
        let (t, c): (String, Color) = {
            if !a.isEnabled { return ("已停用", .gray) }
            switch status.states[a.id] ?? .unknown {
            case .ok: return ("已连接", .green)
            case .syncing: return ("同步中", .blue)
            case .failed: return ("连接失败", .red)
            case .unknown: return ("未检测", .gray)
            }
        }()
        Text(t).font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.15))).foregroundStyle(c)
    }
}

/// 账户编辑
struct AccountEditView: View {
    @Bindable var account: Account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var allAccounts: [Account]
    @State private var confirmDelete = false
    @State private var password = ""
    @State private var reveal = false
    @State private var testing = false
    @State private var testResult: (Bool, String)?
    @State private var aliasText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("邮箱", value: account.email)
                    TextField("显示名称", text: $account.displayName)
                    TextField("发件人名称（收件人看到的名字）", text: $account.senderName)
                    Toggle("启用此账户", isOn: $account.isEnabled)
                } header: { Text("基本") }
                Section {
                    Picker("颜色", selection: $account.colorIndex) {
                        ForEach(Prefs.palette.indices, id: \.self) { i in
                            Label(Prefs.paletteNames[i], systemImage: "circle.fill").foregroundStyle(Prefs.palette[i]).tag(i)
                        }
                    }
                    TextField("分组（如 工作 / 个人）", text: $account.groupName)
                    let existing = Array(Set(allAccounts.map(\.groupName).filter { !$0.isEmpty })).sorted()
                    if !existing.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack { ForEach(existing, id: \.self) { g in Button(g) { account.groupName = g }.buttonStyle(.bordered).controlSize(.small) } }
                        }
                    }
                } header: { Text("外观与分组") }
                Section {
                    switch account.authKind {
                    case .password:
                        HStack {
                            Group {
                                if reveal { TextField("密码 / 授权码", text: $password) } else { SecureField("密码 / 授权码", text: $password) }
                            }
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }.buttonStyle(.borderless)
                        }
                    case .oauthGoogle, .oauthMicrosoft:
                        Button(account.authKind == .oauthGoogle ? "重新使用 Google 登录" : "重新使用 Microsoft 登录", systemImage: "person.badge.key") {
                            Task { await reauth() }
                        }
                    }
                } header: { Text("登录") }
                Section("IMAP 收信") {
                    TextField("服务器", text: $account.imapHost).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("端口", value: $account.imapPort, format: .number.grouping(.never)).keyboardType(.numberPad)
                    Toggle("SSL/TLS", isOn: $account.imapTLS)
                }
                Section("SMTP 发信") {
                    TextField("服务器", text: $account.smtpHost).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("端口", value: $account.smtpPort, format: .number.grouping(.never)).keyboardType(.numberPad)
                    Picker("安全", selection: $account.smtpImplicitTLS) { Text("SSL (465)").tag(true); Text("STARTTLS (587)").tag(false) }
                }
                Section {
                    ForEach(account.aliases, id: \.self) { Text($0) }
                        .onDelete { account.aliases.remove(atOffsets: $0) }
                    HStack {
                        TextField("添加别名地址", text: $aliasText).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        Button("添加") { account.aliases.append(aliasText.trimmingCharacters(in: .whitespaces)); aliasText = "" }
                            .disabled(!aliasText.contains("@"))
                    }
                } header: { Text("发件别名") }
                Section("签名") { TextEditor(text: $account.signature).frame(minHeight: 90) }
                Section {
                    Button { Task { await test() } } label: {
                        HStack { Text("测试连接"); Spacer(); if testing { ProgressView() } }
                    }.disabled(testing)
                    if let r = testResult {
                        Label(r.1, systemImage: r.0 ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(r.0 ? .green : .red).font(.callout)
                    }
                }
                Section { Button("删除账户", role: .destructive) { confirmDelete = true } }
            }
            .navigationTitle("编辑账户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { context.rollback(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save(); dismiss() }.bold() }
            }
            .confirmationDialog("删除该账户及本地缓存？此操作不会删除服务器上的邮件。", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    KeychainStore.deleteAll(accountID: account.id)
                    context.delete(account); try? context.save(); dismiss()
                }
            }
        }
    }

    private func save() {
        if !password.isEmpty, account.authKind == .password { KeychainStore.set(password, for: "\(account.id).password") }
        try? context.save()
        IdleManager.shared.restart(container: context.container)
    }

    private func test() async {
        testing = true; testResult = nil; defer { testing = false }
        if !password.isEmpty, account.authKind == .password { KeychainStore.set(password, for: "\(account.id).password") }
        let cfg = AccountConfig(account)
        do {
            let imap = try await cfg.openIMAP(); await imap.logout()
            AccountStatus.set(account.id, .ok)
            testResult = (true, "IMAP 登录成功")
        } catch {
            AccountStatus.set(account.id, .failed(error.localizedDescription))
            testResult = (false, "连接失败：\(error.localizedDescription)")
        }
    }

    private func reauth() async {
        do {
            let t = try await OAuthService.shared.authorize(account.authKind, loginHint: account.email)
            CredentialProvider.save(t, accountID: account.id)
            testResult = (true, "已重新登录")
        } catch { testResult = (false, error.localizedDescription) }
    }
}
