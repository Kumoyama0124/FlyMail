import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PDFKit

struct AIChatView: View {
    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    var initialPrompt: String? = nil

    @State private var messages: [AIChatMessage] = []
    @State private var conversations: [AIConversation] = []
    @State private var currentConversationID: String?
    @State private var input = ""
    @State private var draftAttachments: [AIChatAttachment] = []
    @State private var sending = false
    @State private var error: String?
    @State private var searchText = ""
    @State private var showSidebar = false
    @State private var showAISettings = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedProfileID = ""
    @State private var reasoningLevel: AIReasoningLevel = .off
    @State private var loadingAttachments = false
    @State private var isSelecting = false
    @State private var selectedConversationIDs: Set<String> = []
    @State private var showArchived = false
    @FocusState private var focused: Bool

    @AppStorage(AIPersonalization.enterToSendKey) private var enterToSend = false
    @AppStorage(AIPersonalization.nameKey) private var assistantName = "FlyMail 助手"
    @AppStorage(Prefs.myNickname) private var myNickname = ""
    @AppStorage(AIPersonaCardStore.showAvatarKey) private var showAvatar = true
    @AppStorage(AIPersonaCardStore.showNameKey) private var showName = true
    /// 聊天头像：我 = 我的头像，AI = 助手资料卡头像
    @State private var myChatAvatar: UIImage?
    @State private var aiChatAvatar: UIImage?

    private var profiles: [AIModelProfile] { AIModelStore.loadProfiles() }
    private var selectedProfile: AIModelProfile? {
        if selectedProfileID.isEmpty { return FlyMailAI.primaryProfile() }
        return profiles.first(where: { $0.id == selectedProfileID })
    }
    private func conversationsMatchingSearch(_ list: [AIConversation]) -> [AIConversation] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return list }
        return list.filter {
            $0.title.localizedCaseInsensitiveContains(keyword) ||
            $0.messages.contains { $0.content.localizedCaseInsensitiveContains(keyword) }
        }
    }
    private var activeConversations: [AIConversation] {
        conversationsMatchingSearch(conversations.filter { !$0.isArchived })
    }
    private var archivedConversations: [AIConversation] {
        conversationsMatchingSearch(conversations.filter { $0.isArchived })
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .leading) {
                // 浅灰底：和系统一样，让白色输入框、白色 dock 从背景里“浮”出来
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                    mainContent
                }

                if showSidebar {
                    Color.black.opacity(0.22)
                        .ignoresSafeArea()
                        .onTapGesture { closeSidebar() }
                        .transition(.opacity)
                        .zIndex(10)

                    historySidebar
                        .frame(width: min(UIScreen.main.bounds.width * 0.82, 340))
                        .frame(maxHeight: .infinity)
                        .background(.regularMaterial)
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5)
                        }
                        .ignoresSafeArea(edges: .vertical)
                        .transition(.move(edge: .leading))
                        .zIndex(11)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showAISettings) {
                NavigationStack { AISettingsView() }
            }
            .onChange(of: showAISettings) { _, open in
                // 设置里刚换过头像/昵称/助手名：关掉设置立即刷新聊天头像，不用退出 AI 页
                if !open {
                    let myURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("MyAvatar.png")
                    myChatAvatar = UIImage(contentsOfFile: myURL.path)
                    aiChatAvatar = AIPersonaCardStore.loadAvatar()
                }
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $selectedPhotos,
                maxSelectionCount: 5,
                matching: .images
            )
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.image, .pdf, .plainText, .rtf, .commaSeparatedText, .json, .data],
                allowsMultipleSelection: true,
                onCompletion: importFiles
            )
            .onChange(of: selectedPhotos) { _, items in
                guard !items.isEmpty else { return }
                Task { await importPhotos(items) }
            }
            .onAppear(perform: restoreConversations)
            .onChange(of: showSidebar) { _, open in
                // 侧栏展开时通知 RootView 收起底部 dock，避免 dock 压住侧栏右下角内容。
                app.isAIHistorySidebarOpen = open
            }
            .onChange(of: focused) { _, isFocused in
                // 键盘弹出时 dock 让位，输入框顶格贴住键盘；收起键盘后 dock 回来。
                app.isAIComposerFocused = isFocused
            }
            .onDisappear {
                app.isAIHistorySidebarOpen = false
                app.isAIComposerFocused = false
            }
            .alert(
                L10n.t("AI 请求失败"),
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
            ) {
                Button(L10n.t("好")) { }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                    showSidebar.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("对话历史")
            .accessibilityIdentifier("ai.history")

            Spacer(minLength: 8)

            Button {
                showAISettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("AI 设置")
            .accessibilityIdentifier("ai.settings")

            Button(action: newConversation) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("新建对话")
            .accessibilityIdentifier("ai.newConversation")
        }
        .padding(.horizontal, 20)
        .padding(.top, 7)
        .padding(.bottom, 8)
    }

    /// 空状态标题：助手名放在“AI”的位置，名字两侧留空格，醒目一点。
    /// 用户没改过名字时保持“开始与 AI 对话”。
    private var emptyStateTitle: String {
        if !FlyMailAI.hasReadyModel { return L10n.t("AI 尚未配置") }
        let name = assistantName.trimmingCharacters(in: .whitespaces)
        return (name.isEmpty || name == "FlyMail 助手") ? L10n.t("开始与 AI 对话") : L10n.t("开始与 %@ 对话", name)
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if messages.isEmpty {
                VStack(spacing: 10) {
                    Spacer(minLength: 0)
                    ContentUnavailableView(
                        emptyStateTitle,
                        systemImage: "sparkles",
                        description: Text(
                            FlyMailAI.hasReadyModel
                            ? L10n.t("可以直接提问，也可以添加图片或文件。邮件内容不会自动加入对话。")
                            : L10n.t("请先点击右上角齿轮，在 AI 设置中添加模型并保存 API Key。")
                        )
                    )
                    if !FlyMailAI.hasReadyModel {
                        Button(L10n.t("打开 AI 设置")) { showAISettings = true }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 4)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(messages) { message in
                                messageRow(message)
                                    .id(message.id)
                            }

                            if sending {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text(L10n.t("AI 正在思考…")).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }

                            Color.clear.frame(height: 80).id("chat-bottom")
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 18)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: messages.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("chat-bottom", anchor: .bottom)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            composer
                .padding(.horizontal, 14)
                .padding(.top, 8)
                // Dock 悬浮在 RootView 上；键盘弹出时 dock 让位，预留空间同步收窄，输入框顶格贴住键盘。
                .padding(.bottom, focused ? 8 : 76)
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: focused)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func messageRow(_ message: AIChatMessage) -> some View {
        let isUser = message.role == "user"
        return HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 20) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
                // 头像和名称在同一行（头像贴屏幕外侧），气泡在下面占整行——微信/QQ 的排版
                if showAvatar || showName {
                    HStack(spacing: 7) {
                        if !isUser {
                            if showAvatar { chatAvatar(isUser: false) }
                            if showName { chatNameLabel(isUser: false) }
                        } else {
                            if showName { chatNameLabel(isUser: true) }
                            if showAvatar { chatAvatar(isUser: true) }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                bubble(for: message)
            }

            if !isUser { Spacer(minLength: 20) }
        }
    }

    private func chatNameLabel(isUser: Bool) -> some View {
        Text(isUser
             ? (myNickname.isEmpty ? "我" : myNickname)
             : (assistantName.isEmpty ? "AI 助手" : assistantName))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func bubble(for message: AIChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(message.attachments) { attachment in
                        Label(attachment.fileName, systemImage: attachment.isImage ? "photo" : "doc")
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
            }

            if !message.content.isEmpty {
                Text(message.content)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .background(
            message.role == "user"
            ? Color.accentColor.opacity(0.13)
            // 页面底色是 systemGroupedBackground（浅灰），助手气泡再用 secondarySystemBackground
            // 会和背景同色“隐形”；浅色下用白卡、深色下用抬高一档的深灰。
            : (colorScheme == .dark
               ? Color(uiColor: .secondarySystemBackground)
               : Color(uiColor: .systemBackground)),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    /// 聊天气泡旁的头像：我 = “我的”页头像，AI = 助手资料卡头像；没设置时用首字母/星标兜底
    private func chatAvatar(isUser: Bool) -> some View {
        Group {
            if isUser {
                if let myChatAvatar {
                    Image(uiImage: myChatAvatar).resizable().scaledToFill()
                } else {
                    ZStack {
                        Circle().fill(Color.accentColor.opacity(0.15))
                        Text(String((myNickname.isEmpty ? "我" : myNickname).prefix(1)))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                if let aiChatAvatar {
                    Image(uiImage: aiChatAvatar).resizable().scaledToFill()
                } else {
                    ZStack {
                        Circle().fill(Color.blue)
                        Image(systemName: "sparkles")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
    }

    private var composer: some View {
        VStack(spacing: 9) {
            if !draftAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(draftAttachments) { attachment in
                            HStack(spacing: 6) {
                                Image(systemName: attachment.isImage ? "photo" : "doc.text")
                                Text(attachment.fileName).lineLimit(1)
                                Button {
                                    draftAttachments.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.secondary.opacity(0.10), in: Capsule())
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 9) {
                Menu {
                    Section {
                        Button { showPhotoPicker = true } label: {
                            Label(L10n.t("选择照片"), systemImage: "photo")
                        }
                        Button { showFileImporter = true } label: {
                            Label(L10n.t("添加文件"), systemImage: "doc")
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 38, height: 38)
                        .background(Color.accentColor.opacity(0.10), in: Circle())
                }
                .accessibilityLabel("添加图片或文件")

                TextField("发送消息…", text: $input, prompt: Text(composerPlaceholder), axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .submitLabel(enterToSend ? .send : .return)
                    .onSubmit {
                        if enterToSend { send() }
                    }
                    .padding(.vertical, 9)
                    .padding(.horizontal, 3)

                // “更多”收成圆形按钮，放在发送左边；模型与思考等级不再单独占一整行。
                Menu {
                    moreMenuContent
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 38, height: 38)
                        .background(Color.secondary.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("更多选项")

                Button(action: send) {
                    Group {
                        if sending || loadingAttachments {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 17, weight: .bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.blue, in: Circle())
                }
                .disabled(
                    (input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftAttachments.isEmpty) ||
                    sending || loadingAttachments
                )
                .accessibilityLabel("发送")
            }
        }
        .padding(12)
        .background {
            // 对齐参考样式：干净的白色胶囊 + 发丝描边 + 柔和投影，不再用 glassEffect。
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .fill(
                    colorScheme == .dark
                    ? Color(uiColor: .secondarySystemBackground)
                    : Color(uiColor: .systemBackground)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 25, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
        }
    }

    /// “更多”菜单内容：切换模型 + 调思考等级（原先铺在输入框下方一整行，现在收进圆形按钮）。
    @ViewBuilder
    private var moreMenuContent: some View {
        Section(L10n.t("模型")) {
            Button {
                selectedProfileID = ""
                reasoningLevel = .off
            } label: {
                if selectedProfileID.isEmpty {
                    Label(L10n.t("首选模型（自动回退）"), systemImage: "checkmark")
                } else {
                    Text(L10n.t("首选模型（自动回退）"))
                }
            }
            ForEach(profiles) { profile in
                Button {
                    selectedProfileID = profile.id
                    reasoningLevel = profile.reasoningDefault
                } label: {
                    if selectedProfileID == profile.id {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
        }
        if let selectedProfile, FlyMailAI.canControlReasoning(selectedProfile) {
            Section(L10n.t("思考等级")) {
                ForEach(FlyMailAI.reasoningOptions(for: selectedProfile)) { level in
                    let title = FlyMailAI.reasoningTitle(level, for: selectedProfile)
                    Button {
                        reasoningLevel = level
                    } label: {
                        if reasoningLevel == level {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            }
        } else {
            Section(L10n.t("思考等级")) {
                Text(L10n.t("当前模型不支持单独调整思考等级"))
            }
        }
        if let selectedProfile, selectedProfile.provider == .gemini,
           selectedProfile.model.lowercased().contains("2.5"), selectedProfile.model.lowercased().contains("pro") {
            Text("Gemini 2.5 Pro 不支持完全关闭思考。")
        }
    }

    /// 输入框为空时把当前模型与思考等级展示在输入框里；开始输入（或已有附件）后让位给正常占位文案。
    private var composerPlaceholder: String {
        guard input.isEmpty, draftAttachments.isEmpty else { return L10n.t("发送消息…") }
        guard let profile = selectedProfile else { return L10n.t("发送消息…") }
        let reasoning = reasoningLevel == .off
            ? L10n.t("思考已关闭")
            : "思考 · \(FlyMailAI.reasoningTitle(reasoningLevel, for: profile))"
        return "\(profile.name) · \(reasoning)"
    }

    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(L10n.t("对话"))
                    .font(.title2.bold())
                Spacer(minLength: 0)
                Button {
                    if isSelecting {
                        isSelecting = false
                        selectedConversationIDs.removeAll()
                    } else {
                        isSelecting = true
                    }
                } label: {
                    Text(L10n.t(isSelecting ? "完成" : "编辑"))
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("ai.history.edit")
                Button { closeSidebar() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.secondary.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 58)

            Button(action: newConversation) {
                Label(L10n.t("新建对话"), systemImage: "plus")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.t("搜索历史对话"), text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(11)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))

            if isSelecting {
                HStack(spacing: 12) {
                    let allSelected = !activeConversations.isEmpty
                        && selectedConversationIDs.count >= activeConversations.count
                    Button(allSelected ? L10n.t("全不选") : L10n.t("全选")) {
                        if allSelected {
                            selectedConversationIDs.removeAll()
                        } else {
                            selectedConversationIDs = Set(activeConversations.map(\.id))
                        }
                    }
                    .font(.subheadline)
                    Spacer(minLength: 0)
                    Text(L10n.t("已选 %lld", selectedConversationIDs.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            List {
                Section {
                    ForEach(activeConversations) { conversation in
                        conversationRow(conversation)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    deleteConversation(conversation)
                                } label: {
                                    Label(L10n.t("删除"), systemImage: "trash")
                                }
                                Button {
                                    setArchived(conversation, archived: true)
                                } label: {
                                    Label(L10n.t("归档"), systemImage: "archivebox")
                                }
                                .tint(.blue)
                            }
                    }
                } header: {
                    Text(searchText.isEmpty ? L10n.t("最近对话") : L10n.t("搜索结果"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if !archivedConversations.isEmpty {
                    Section {
                        if showArchived {
                            ForEach(archivedConversations) { conversation in
                                conversationRow(conversation)
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            deleteConversation(conversation)
                                        } label: {
                                            Label(L10n.t("删除"), systemImage: "trash")
                                        }
                                        Button {
                                            setArchived(conversation, archived: false)
                                        } label: {
                                            Label(L10n.t("恢复"), systemImage: "tray.and.arrow.up")
                                        }
                                        .tint(.blue)
                                    }
                            }
                        }
                    } header: {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { showArchived.toggle() }
                        } label: {
                            Label(
                                L10n.t("已归档 %lld", archivedConversations.count),
                                systemImage: showArchived ? "chevron.down" : "chevron.right"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            if isSelecting {
                HStack(spacing: 10) {
                    Button {
                        archiveSelected()
                    } label: {
                        Label(L10n.t("归档所选"), systemImage: "archivebox")
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedConversationIDs.isEmpty)

                    Button(role: .destructive) {
                        deleteSelected()
                    } label: {
                        Label(L10n.t("删除所选"), systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(selectedConversationIDs.isEmpty)

                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield").foregroundStyle(.secondary)
                    Text(L10n.t("对话和记忆仅保存在本机"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 30)
            }
        }
        .padding(.horizontal, 16)
    }

    private func conversationRow(_ conversation: AIConversation) -> some View {
        let isSelected = selectedConversationIDs.contains(conversation.id)
        return Button {
            if isSelecting {
                toggleSelection(conversation.id)
            } else {
                openConversation(conversation)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .padding(.top, 1)
                } else {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    Text(conversation.updatedAt, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if conversation.id == currentConversationID, !isSelecting {
                    Circle().fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .padding(.top, 6)
                }
            }
            .padding(10)
            .background(
                conversation.id == currentConversationID && !isSelecting
                ? Color.accentColor.opacity(0.10)
                : Color.clear,
                in: RoundedRectangle(cornerRadius: 11)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
    }

    private func restoreConversations() {
        conversations = AIConversationStore.load()
        // 聊天头像：我的头像 + 助手资料卡头像（每次进页面重新读，改头像立即生效）
        let myURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyAvatar.png")
        myChatAvatar = UIImage(contentsOfFile: myURL.path)
        aiChatAvatar = AIPersonaCardStore.loadAvatar()
        selectedProfileID = ""
        if let current = conversations.first {
            currentConversationID = current.id
            messages = current.messages
        } else {
            createConversation(persist: false)
        }
        if let initialPrompt, input.isEmpty { input = initialPrompt }
    }

    private func createConversation(persist: Bool) {
        let conversation = AIConversation(title: "新对话")
        currentConversationID = conversation.id
        messages = []
        draftAttachments = []
        input = ""
        if persist {
            conversations.insert(conversation, at: 0)
            AIConversationStore.save(conversations)
        }
    }

    private func newConversation() {
        focused = false
        // 当前已经在一条空对话里时不重复创建，只收起侧栏，避免“点了没反应”。
        if messages.isEmpty, input.isEmpty, draftAttachments.isEmpty {
            closeSidebar()
            focused = true
            return
        }
        createConversation(persist: true)
        closeSidebar()
        focused = true
    }

    private func openConversation(_ conversation: AIConversation) {
        currentConversationID = conversation.id
        messages = conversation.messages
        draftAttachments = []
        input = ""
        focused = false
        closeSidebar()
    }

    private func closeSidebar() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
            showSidebar = false
        }
    }

    private func deleteConversation(_ conversation: AIConversation) {
        conversations.removeAll { $0.id == conversation.id }
        AIConversationStore.save(conversations)
        selectedConversationIDs.remove(conversation.id)
        if currentConversationID == conversation.id {
            createConversation(persist: false)
        }
    }

    private func setArchived(_ conversation: AIConversation, archived: Bool) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[index].isArchived = archived
        AIConversationStore.save(conversations)
    }

    private func toggleSelection(_ id: String) {
        if selectedConversationIDs.contains(id) {
            selectedConversationIDs.remove(id)
        } else {
            selectedConversationIDs.insert(id)
        }
    }

    private func archiveSelected() {
        guard !selectedConversationIDs.isEmpty else { return }
        let ids = selectedConversationIDs
        for id in ids {
            if let index = conversations.firstIndex(where: { $0.id == id }) {
                conversations[index].isArchived = true
            }
        }
        AIConversationStore.save(conversations)
        selectedConversationIDs.removeAll()
    }

    private func deleteSelected() {
        guard !selectedConversationIDs.isEmpty else { return }
        let deleting = selectedConversationIDs
        conversations.removeAll { deleting.contains($0.id) }
        if let current = currentConversationID, deleting.contains(current) {
            createConversation(persist: false)
        }
        AIConversationStore.save(conversations)
        selectedConversationIDs.removeAll()
    }

    private func saveCurrentConversation() {
        guard let id = currentConversationID else { return }
        let firstUserText = messages.first(where: { $0.role == "user" })?.content ?? ""
        let title = String(firstUserText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        let conversation = AIConversation(
            id: id,
            title: title.isEmpty ? "新对话" : title,
            messages: messages,
            updatedAt: .now
        )
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
        conversations.sort { $0.updatedAt > $1.updatedAt }
        AIConversationStore.save(conversations)
    }

    private func saveConversation(id: String, messages savedMessages: [AIChatMessage]) {
        let firstUserText = savedMessages.first(where: { $0.role == "user" })?.content ?? ""
        let title = String(firstUserText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        let conversation = AIConversation(
            id: id,
            title: title.isEmpty ? "新对话" : title,
            messages: savedMessages,
            updatedAt: .now
        )
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
        conversations.sort { $0.updatedAt > $1.updatedAt }
        AIConversationStore.save(conversations)
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !draftAttachments.isEmpty), !sending, !loadingAttachments else { return }
        guard FlyMailAI.hasReadyModel else {
            showAISettings = true
            return
        }

        let userMessage = AIChatMessage(role: "user", content: text, attachments: draftAttachments)
        messages.append(userMessage)
        input = ""
        draftAttachments = []
        focused = false
        sending = true
        saveCurrentConversation()

        // 已有自动摘要时，只发送最近 8 条原始消息；更早的上下文由本机长期记忆摘要承接。
        // 完整聊天记录仍保留在本地侧栏中，不会被删除。
        let requestConversationID = currentConversationID
        let requestMessages: [AIChatMessage]
        if AIMemoryStore.isEnabled,
           let requestConversationID,
           AIMemoryStore.compactedCount(for: requestConversationID) > 0,
           messages.count > 8 {
            requestMessages = Array(messages.suffix(8))
        } else {
            requestMessages = messages
        }
        let requestProfileID = selectedProfileID.isEmpty ? nil : selectedProfileID
        let requestReasoning = reasoningLevel

        Task {
            do {
                let answer = try await FlyMailAI.chat(
                    messages: requestMessages,
                    profileID: requestProfileID,
                    reasoning: requestReasoning,
                    memoryConversationID: requestConversationID
                )
                await MainActor.run {
                    let answerMessage = AIChatMessage(role: "assistant", content: answer)
                    if currentConversationID == requestConversationID {
                        messages.append(answerMessage)
                        saveCurrentConversation()
                        compactMemoryIfNeeded(conversationID: requestConversationID, conversationMessages: messages)
                    } else if let requestConversationID,
                              let index = conversations.firstIndex(where: { $0.id == requestConversationID }) {
                        var completedMessages = conversations[index].messages
                        completedMessages.append(answerMessage)
                        saveConversation(id: requestConversationID, messages: completedMessages)
                        compactMemoryIfNeeded(conversationID: requestConversationID, conversationMessages: completedMessages)
                    }
                    sending = false
                }
            } catch {
                let errorMessage = error.localizedDescription
                await MainActor.run {
                    if currentConversationID == requestConversationID {
                        self.error = errorMessage
                    }
                    sending = false
                }
            }
        }
    }

    private func compactMemoryIfNeeded(conversationID: String?, conversationMessages: [AIChatMessage]) {
        guard AIMemoryStore.isEnabled,
              let conversationID,
              conversationMessages.count >= 20 else { return }

        let alreadyCompacted = AIMemoryStore.compactedCount(for: conversationID)
        guard conversationMessages.count - alreadyCompacted >= 12 else { return }

        let boundary = max(0, conversationMessages.count - 8)
        guard boundary > 0 else { return }
        let oldMessages = Array(conversationMessages.prefix(boundary))
        let count = conversationMessages.count

        Task {
            do {
                let summary = try await FlyMailAI.compactMemory(messages: oldMessages, conversationID: conversationID)
                await MainActor.run {
                    AIMemoryStore.saveSummary(summary, compactedCount: count, conversationID: conversationID)
                }
            } catch {
                // 自动记忆失败不打断当前对话；下次达到阈值时会再次尝试。
            }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let importError):
            error = importError.localizedDescription
        case .success(let urls):
            Task { await importFileURLs(urls) }
        }
    }

    private func importFileURLs(_ urls: [URL]) async {
        await MainActor.run { loadingAttachments = true }
        var imported: [AIChatAttachment] = []
        var failures: [String] = []

        for url in urls {
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            let fileName = url.lastPathComponent
            do {
                if type?.conforms(to: .image) == true {
                    let data = try Data(contentsOf: url)
                    let mime = type?.preferredMIMEType ?? "image/jpeg"
                    imported.append(try AIChatAttachmentStore.save(data: data, fileName: fileName, mimeType: mime))
                } else if type?.conforms(to: .pdf) == true {
                    let pdfText = PDFDocument(url: url)?.string ?? ""
                    guard !pdfText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        failures.append("\(fileName)：无法读取 PDF 文本")
                        continue
                    }
                    input += (input.isEmpty ? "" : "\n\n") + "[附件：\(fileName)]\n" + String(pdfText.prefix(24000))
                    imported.append(try AIChatAttachmentStore.save(data: Data(), fileName: fileName, mimeType: "application/pdf"))
                } else {
                    let data = try Data(contentsOf: url)
                    guard let text = String(data: data, encoding: .utf8) else {
                        failures.append("\(fileName)：目前只支持 PDF、图片和 UTF-8 文本文件")
                        continue
                    }
                    input += (input.isEmpty ? "" : "\n\n") + "[附件：\(fileName)]\n" + String(text.prefix(24000))
                    imported.append(try AIChatAttachmentStore.save(data: Data(), fileName: fileName, mimeType: type?.preferredMIMEType ?? "text/plain"))
                }
            } catch {
                failures.append("\(fileName)：\(error.localizedDescription)")
            }
        }

        await MainActor.run {
            draftAttachments.append(contentsOf: imported)
            loadingAttachments = false
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        await MainActor.run { loadingAttachments = true }
        var imported: [AIChatAttachment] = []

        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let mime = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            if let attachment = try? AIChatAttachmentStore.save(
                data: data,
                fileName: "图片-\(imported.count + 1).\(ext)",
                mimeType: mime
            ) {
                imported.append(attachment)
            }
        }

        await MainActor.run {
            draftAttachments.append(contentsOf: imported)
            selectedPhotos = []
            loadingAttachments = false
        }
    }
}
