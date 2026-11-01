import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ComposeView: View {
    @State var draft: ComposeDraft
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @State private var showCc = false
    @State private var importing = false
    @State private var scheduled = false
    @State private var sendAt = Date.now.addingTimeInterval(3600)
    @State private var sending = false
    @State private var lastLocalSave: ComposeDraft?
    @State private var lastServerSave: ComposeDraft?
    @State private var lastServerSaveTime = Date.distantPast
    @State private var confirmClose = false
    @State private var finished = false
    // 写信助手
    @State private var aiBusy = false
    @State private var aiResult: AIComposeResult?
    @State private var bodyBeforeAI: String?
    private let autosave = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("发件账户", selection: $draft.accountID) {
                        ForEach(accounts) { Text($0.email).tag(Optional($0.id)) }
                    }
                    TextField("收件人", text: $draft.to).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    if showCc {
                        TextField("抄送", text: $draft.cc).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        TextField("密送", text: $draft.bcc).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    } else { Button("添加抄送/密送") { showCc = true } }
                    TextField("主题", text: $draft.subject)
                }
                Section { TextEditor(text: $draft.body).frame(minHeight: 240) }
                Section("附件") {
                    ForEach(draft.attachments) { a in
                        Label("\(a.filename)（\(ByteCountFormatter.string(fromByteCount: Int64(a.data.count), countStyle: .file))）", systemImage: "paperclip")
                    }
                    .onDelete { draft.attachments.remove(atOffsets: $0) }
                    Button("添加附件", systemImage: "plus") { importing = true }
                }
                Section {
                    Toggle("定时发送", isOn: $scheduled)
                    if scheduled { DatePicker("发送时间", selection: $sendAt, in: Date.now...) }
                }
            }
            .navigationTitle("写邮件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { if isEmpty { discard() } else { confirmClose = true } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 14) {
                        // 写信助手：对当前正文做润色/改语气/翻译等，结果可预览后替换
                        Menu {
                            Button { aiAssist("润色", "请润色以下邮件正文，使表达更清晰、自然、专业，不改变原意，保留原有分段。只输出润色后的正文。") } label: { Label("润色", systemImage: "wand.and.stars") }
                            Button { aiAssist("改得更正式", "请把以下邮件正文改写得更正式、更专业，不改变原意。只输出改写后的正文。") } label: { Label("改得更正式", systemImage: "briefcase") }
                            Button { aiAssist("改得更简洁", "请把以下邮件正文精简（大约一半篇幅），保留全部关键信息。只输出结果。") } label: { Label("改得更简洁", systemImage: "arrow.down.right.and.arrow.up.left") }
                            Button { aiAssist("扩写", "请在不编造事实的前提下，把以下邮件正文扩写得更完整、更有说服力。只输出结果。") } label: { Label("扩写", systemImage: "arrow.up.left.and.arrow.down.right") }
                            Divider()
                            Button { aiAssist("翻译成英文", "请将以下邮件正文翻译成地道的英文，保留原有分段。只输出译文。") } label: { Label("翻译成英文", systemImage: "globe") }
                            Button { aiAssist("翻译成中文", "请将以下邮件正文翻译成简体中文，保留原有分段。只输出译文。") } label: { Label("翻译成中文", systemImage: "globe.asia.australia") }
                            Divider()
                            Button { aiAssist("检查错别字", "请检查以下邮件正文中的错别字和语病，直接输出修正后的全文；没有问题就原样输出，不要解释。") } label: { Label("检查错别字", systemImage: "checkmark.circle") }
                        } label: {
                            if aiBusy { ProgressView() } else { Image(systemName: "sparkles") }
                        }
                        .disabled(aiBusy || draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button(scheduled ? "安排" : "发送") { Task { await send() } }
                            .disabled(sending || draft.accountID == nil || MIMEParser.addresses(draft.to).isEmpty)
                    }
                }
            }
            .sheet(item: $aiResult) { result in
                AIComposeResultSheet(result: result, bodyBeforeAI: bodyBeforeAI) { restored in
                    if let restored { draft.body = restored; bodyBeforeAI = nil }
                    aiResult = nil
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
                for url in (try? r.get()) ?? [] {
                    guard url.startAccessingSecurityScopedResource() else { continue }
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let d = try? Data(contentsOf: url) {
                        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                        draft.attachments.append(AttachmentData(filename: url.lastPathComponent, mimeType: type, data: d))
                    }
                }
            }
            .interactiveDismissDisabled(!isEmpty)
            .confirmationDialog("关闭写信", isPresented: $confirmClose) {
                Button("保存草稿") { Task { await saveDraft(server: true); finished = true; dismiss() } }
                Button("删除草稿", role: .destructive) { discard() }
                Button("继续编辑", role: .cancel) {}
            }
            .onReceive(autosave) { _ in
                guard !isEmpty else { return }
                Task { await saveDraft(server: Date.now.timeIntervalSince(lastServerSaveTime) > 30) }
            }
            .onDisappear { if !finished && !isEmpty { LocalDraftStore.save(draft) } }
            .onAppear {
                if draft.accountID == nil {
                    let pref = UUID(uuidString: UserDefaults.standard.string(forKey: Prefs.defaultAccount) ?? "")
                    draft.accountID = accounts.first(where: { $0.id == pref })?.id ?? accounts.first?.id
                }
                if draft.body.isEmpty {
                    if let card = profileSignatureCard() { draft.body = card }
                    else if let a = accounts.first(where: { $0.id == draft.accountID }) { draft.body = a.signature }
                }
            }
        }
    }

    /// “我的”页的签名名片：开关开着、且填了昵称或签名时才用；
    /// 格式是昵称 + 签名 + 首个账户邮箱，前面空两行，放在正文末尾
    private func profileSignatureCard() -> String? {
        guard UserDefaults.standard.bool(forKey: Prefs.mySignatureCard) || UserDefaults.standard.object(forKey: Prefs.mySignatureCard) == nil else { return nil }
        let name = UserDefaults.standard.string(forKey: Prefs.myNickname) ?? ""
        let sig = UserDefaults.standard.string(forKey: Prefs.mySignature) ?? ""
        guard !name.isEmpty || !sig.isEmpty else { return nil }
        var lines = ["— \(name.isEmpty ? (accounts.first?.displayName ?? "") : name)"]
        if !sig.isEmpty { lines.append(sig) }
        let chosen = UserDefaults.standard.string(forKey: Prefs.myEmail) ?? ""
        if let email = (chosen.isEmpty ? accounts.first?.email : chosen), !email.isEmpty { lines.append(email) }
        return "\n\n" + lines.joined(separator: "\n")
    }

    private var isEmpty: Bool {
        draft.to.isEmpty && draft.subject.isEmpty && draft.attachments.isEmpty &&
        (draft.body.isEmpty || draft.body == accounts.first(where: { $0.id == draft.accountID })?.signature
         || (profileSignatureCard() != nil && draft.body == profileSignatureCard()))
    }

    /// 本地每 5 秒保存；服务器约每 30 秒及关闭时保存（替换上一版）
    private func saveDraft(server: Bool) async {
        if draft != lastLocalSave {
            draft.updatedAt = .now
            LocalDraftStore.save(draft)
            lastLocalSave = draft
        }
        guard server, draft != lastServerSave, let a = accounts.first(where: { $0.id == draft.accountID }),
              let drafts = a.folder(role: "drafts") else { return }
        lastServerSaveTime = .now
        let snapshot = draft
        do {
            let uid = try await DraftService.saveToServer(snapshot, cfg: AccountConfig(a), draftsPath: drafts.path)
            draft.serverDraftUID = uid
            draft.serverDraftFolder = uid == nil ? nil : drafts.path
            lastServerSave = draft
            lastLocalSave = draft
            LocalDraftStore.save(draft)
        } catch {
            print("草稿同步失败：\(error)")
        }
    }

    private func discard() {
        finished = true
        LocalDraftStore.delete(draft.id)
        if let uid = draft.serverDraftUID, let f = draft.serverDraftFolder,
           let a = accounts.first(where: { $0.id == draft.accountID }) {
            let cfg = AccountConfig(a)
            Task { try? await DraftService.deleteFromServer(uid: uid, folder: f, cfg: cfg) }
        }
        dismiss()
    }

    private func send() async {
        guard let aid = draft.accountID else { return }
        sending = true; defer { sending = false }
        let svc = OutboxService(modelContainer: context.container)
        do {
            try await svc.enqueue(draft, accountID: aid, sendAt: scheduled ? sendAt : .now)
            LocalDraftStore.delete(draft.id)
            finished = true
            if scheduled { BackgroundScheduler.shared.scheduleAll(nextOutbox: sendAt) }
            else { await svc.flushDue() }
            dismiss()
        } catch { app.lastError = error.localizedDescription }
    }

    /// 写信助手：对当前正文跑一次 AI，结果先预览，用户确认后再替换（可撤销）
    private func aiAssist(_ title: String, _ instruction: String) {
        let source = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !aiBusy else { return }
        aiBusy = true
        bodyBeforeAI = draft.body
        let prompt = "\(instruction)\n\n以下是需要处理的邮件内容：\n\n\(draft.body)"
        Task {
            do {
                let text = try await FlyMailAI.chat(messages: [AIChatMessage(role: "user", content: prompt)])
                aiResult = AIComposeResult(title: title, text: text)
            } catch {
                app.lastError = error.localizedDescription
                bodyBeforeAI = nil
            }
            aiBusy = false
        }
    }
}

struct AIComposeResult: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

/// 写信助手结果预览：替换正文前先看一遍，替换错了可以撤销
struct AIComposeResultSheet: View {
    let result: AIComposeResult
    let bodyBeforeAI: String?
    /// 参数为撤销时要恢复的原文；传 nil 表示直接关闭
    let onClose: (String?) -> Void
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(result.text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            UIPasteboard.general.string = result.text
                            copied = true
                        } label: {
                            Label(copied ? "已复制" : "复制结果", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            UIPasteboard.general.string = result.text
                            onClose(result.text)
                        } label: {
                            Label("替换正文", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        if let original = bodyBeforeAI {
                            Button {
                                onClose(original)
                            } label: {
                                Label("撤销，恢复替换前正文", systemImage: "arrow.uturn.backward")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(result.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { onClose(nil) }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
