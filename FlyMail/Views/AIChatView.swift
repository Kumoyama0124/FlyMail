import SwiftUI

struct AIChatView: View {
    @Environment(AppState.self) private var app
    var initialPrompt: String? = nil

    @State private var messages: [AIChatMessage] = []
    @State private var input = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if messages.isEmpty {
                            ContentUnavailableView(
                                FlyMailAI.hasReadyModel ? "开始与 AI 对话" : "AI 尚未配置",
                                systemImage: "bubble.left.and.text",
                                description: Text(
                                    FlyMailAI.hasReadyModel
                                    ? "可以直接提问。邮件内容不会自动加入对话。"
                                    : "先在统一设置入口的「AI」页面添加模型并保存 API Key。"
                                )
                            )
                            .padding(.top, 40)

                            if !FlyMailAI.hasReadyModel {
                                Button("前往设置") { app.showingSettings = true }
                                    .buttonStyle(.borderedProminent)
                            }
                        }

                        ForEach(messages) { message in
                            HStack {
                                if message.role == "user" { Spacer(minLength: 36) }
                                Text(message.content)
                                    .textSelection(.enabled)
                                    .padding(12)
                                    .background(
                                        message.role == "user"
                                        ? Color.accentColor.opacity(0.15)
                                        : Color.secondary.opacity(0.10)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                if message.role != "user" { Spacer(minLength: 36) }
                            }
                        }

                        if sending {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("AI 正在回复…").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                }

                Divider()

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("发送消息…", text: $input, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($focused)
                        .padding(10)
                        .background(.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                    .accessibilityLabel("发送")
                }
                .padding()
                .background(.regularMaterial)
            }
            .navigationTitle("AI")
            .onAppear {
                if let initialPrompt, input.isEmpty { input = initialPrompt }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { app.showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("打开统一设置")

                    Button {
                        messages.removeAll()
                        error = nil
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新对话")
                }
            }
            .alert(
                "AI 请求失败",
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
            ) {
                Button("好") { }
            } message: {
                Text(error ?? "")
            }
        }
        // RootView 的 Dock 是悬浮覆盖层；给 AI 输入区留出空间，避免输入框和发送按钮被 Dock 遮住。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 70).allowsHitTesting(false)
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }

        let userMessage = AIChatMessage(role: "user", content: text)
        let requestMessages = messages + [userMessage]
        messages = requestMessages
        input = ""
        focused = false
        sending = true

        Task {
            do {
                let answer = try await FlyMailAI.chat(messages: requestMessages)
                await MainActor.run {
                    messages.append(AIChatMessage(role: "assistant", content: answer))
                    sending = false
                }
            } catch {
                let errorMessage = error.localizedDescription
                await MainActor.run {
                    self.error = errorMessage
                    sending = false
                }
            }
        }
    }
}
