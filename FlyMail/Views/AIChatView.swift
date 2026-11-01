import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PDFKit

struct AIChatView: View {
    @Environment(AppState.self) private var app

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
    @State private var showAttachOptions = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showMore = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedProfileID = ""
    @State private var reasoningLevel: AIReasoningLevel = .off
    @State private var loadingAttachments = false
    @FocusState private var focused: Bool

    @AppStorage(AIPersonalization.enterToSendKey) private var enterToSend = false

    private var profiles: [AIModelProfile] { AIModelStore.loadProfiles() }
    private var selectedProfile: AIModelProfile? {
        if selectedProfileID.isEmpty { return FlyMailAI.primaryProfile() }
        return profiles.first(where: { $0.id == selectedProfileID })
    }
    private var selectedProfileTitle: String {
        selectedProfileID.isEmpty ? "首选模型" : (selectedProfile?.name ?? "选择模型")
    }
    private var filteredConversations: [AIConversation] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return conversations }
        return conversations.filter {
            $0.title.localizedCaseInsensitiveContains(keyword) ||
            $0.messages.contains { $0.content.localizedCaseInsensitiveContains(keyword) }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .leading) {
                mainContent

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
            .navigationTitle("AI")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                            showSidebar.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .accessibilityLabel("对话历史")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 18) {
                        Button { showAISettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("AI 设置")

                        Button(action: newConversation) {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("新建对话")
                    }
                    .font(.system(size: 18, weight: .medium))
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .glassEffect(.regular, in: Capsule())
                }
            }
            .sheet(isPresented: $showAISettings) {
                NavigationStack { AISettingsView() }
            }
            .confirmationDialog("添加内容", isPresented: $showAttachOptions, titleVisibility: .visible) {
                Button("选择照片") { showPhotoPicker = true }
                Button("添加文件") { showFileImporter = true }
                Button("取消", role: .cancel) { }
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
            .alert(
                "AI 请求失败",
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
            ) {
                Button("好") { }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private var mainContent: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if messages.isEmpty {
                    Spacer()
                    ContentUnavailableView(
                        FlyMailAI.hasReadyModel ? "开始与 AI 对话" : "AI 尚未配置",
                        systemImage: "sparkles",
                        description: Text(
                            FlyMailAI.hasReadyModel
                            ? "可以直接提问，也可以添加图片或文件。邮件内容不会自动加入对话。"
                            : "请先通过右上角齿轮，在 AI 设置中添加模型并保存 API Key。"
                        )
                    )
                    if !FlyMailAI.hasReadyModel {
                        Button("打开 AI 设置") { showAISettings = true }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 10)
                    }
                    Spacer()
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
                                        Text("AI 正在思考…").foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                }

                                Color.clear.frame(height: 180).id("chat-bottom")
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
                }
            }

            composer
                .padding(.horizontal, 14)
                .padding(.bottom, 86)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func messageRow(_ message: AIChatMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == "user" { Spacer(minLength: 46) }

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
                : Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )

            if message.role != "user" { Spacer(minLength: 34) }
        }
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
                Button { showAttachOptions = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 38, height: 38)
                        .background(Color.accentColor.opacity(0.10), in: Circle())
                }
                .accessibilityLabel("添加图片或文件")

                TextField("发送消息…", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .submitLabel(enterToSend ? .send : .return)
                    .onSubmit {
                        if enterToSend { send() }
                    }
                    .padding(.vertical, 9)
                    .padding(.horizontal, 3)

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
                    .background(Color.accentColor, in: Circle())
                }
                .disabled(
                    (input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftAttachments.isEmpty) ||
                    sending || loadingAttachments
                )
                .accessibilityLabel("发送")
            }

            HStack(spacing: 8) {
                Menu {
                    Section("模型") {
                        Button {
                            selectedProfileID = ""
                            reasoningLevel = .off
                        } label: {
                            if selectedProfileID.isEmpty {
                                Label("首选模型（自动回退）", systemImage: "checkmark")
                            } else {
                                Text("首选模型（自动回退）")
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
                        Section("思考等级") {
                            ForEach(AIReasoningLevel.allCases) { level in
                                Button {
                                    reasoningLevel = level
                                } label: {
                                    if reasoningLevel == level {
                                        Label(level.title, systemImage: "checkmark")
                                    } else {
                                        Text(level.title)
                                    }
                                }
                            }
                        }
                    } else {
                        Section("思考等级") {
                            Text("当前模型不支持单独调整思考等级")
                        }
                    }
                    if let selectedProfile, selectedProfile.provider == .gemini,
                       selectedProfile.model.lowercased().contains("2.5"), selectedProfile.model.lowercased().contains("pro") {
                        Text("Gemini 2.5 Pro 不支持完全关闭思考。")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                        Text("更多")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .glassEffect(.regular, in: Capsule())
                }

                Text(selectedProfileTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if selectedProfile != nil {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(reasoningLevel.title + "思考")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if enterToSend {
                    Label("回车发送", systemImage: "return")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if loadingAttachments {
                    ProgressView().scaleEffect(0.75)
                }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 25, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.7)
                }
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        }
        .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
    }

    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("对话")
                    .font(.title2.bold())
                Spacer()
                Button { closeSidebar() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.secondary.opacity(0.12), in: Circle())
                }
            }
            .padding(.top, 58)

            Button(action: newConversation) {
                Label("新建对话", systemImage: "plus")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索历史对话", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(11)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))

            Text(searchText.isEmpty ? "最近对话" : "搜索结果")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filteredConversations) { conversation in
                        Button {
                            openConversation(conversation)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "bubble.left")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 2)
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
                                if conversation.id == currentConversationID {
                                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                                }
                            }
                            .padding(10)
                            .background(
                                conversation.id == currentConversationID
                                ? Color.accentColor.opacity(0.10)
                                : Color.clear,
                                in: RoundedRectangle(cornerRadius: 11)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteConversation(conversation)
                            } label: {
                                Label("删除对话", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                Text("对话和记忆仅保存在本机")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 34)
        }
        .padding(.horizontal, 16)
    }

    private func restoreConversations() {
        conversations = AIConversationStore.load()
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
        createConversation(persist: true)
        closeSidebar()
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
        if currentConversationID == conversation.id {
            createConversation(persist: false)
        }
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

        let requestMessages = messages
        let requestProfileID = selectedProfileID.isEmpty ? nil : selectedProfileID
        let requestReasoning = reasoningLevel

        Task {
            do {
                let answer = try await FlyMailAI.chat(
                    messages: requestMessages,
                    profileID: requestProfileID,
                    reasoning: requestReasoning
                )
                await MainActor.run {
                    messages.append(AIChatMessage(role: "assistant", content: answer))
                    sending = false
                    saveCurrentConversation()
                    compactMemoryIfNeeded()
                }
            } catch {
                let errorMessage = error.localizedDescription
                await MainActor.run {
                    self.error = errorMessage
                    sending = false
                    saveCurrentConversation()
                }
            }
        }
    }

    private func compactMemoryIfNeeded() {
        guard AIMemoryStore.isEnabled,
              let conversationID = currentConversationID,
              messages.count >= 20 else { return }

        let alreadyCompacted = AIMemoryStore.compactedConversationID == conversationID
            ? AIMemoryStore.compactedCount : 0
        guard messages.count - alreadyCompacted >= 12 else { return }

        let boundary = max(0, messages.count - 8)
        guard boundary > 0 else { return }
        let oldMessages = Array(messages.prefix(boundary))
        let count = messages.count

        Task {
            do {
                let summary = try await FlyMailAI.compactMemory(messages: oldMessages)
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
