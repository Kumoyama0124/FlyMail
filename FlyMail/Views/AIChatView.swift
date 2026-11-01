import SwiftUI

struct AIChatView: View {
    @State private var messages: [AIChatMessage] = []
    @State private var input = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if FlyMailAI.model.isEmpty || FlyMailAI.apiKey.isEmpty {
                    ContentUnavailableView("配置 AI 模型", systemImage: "sparkles",
                        description: Text("前往「设置 → AI」填写兼容 API 地址、模型和密钥。"))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if messages.isEmpty {
                                ContentUnavailableView("开始与 AI 对话", systemImage: "bubble.left.and.text",
                                    description: Text("当前为普通聊天。邮件内容不会自动加入对话。"))
                                    .padding(.top, 40)
                            }
                            ForEach(messages) { message in
                                HStack {
                                    if message.role == "user" { Spacer(minLength: 36) }
                                    Text(message.content)
                                        .padding(12)
                                        .background(message.role == "user" ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.10))
                                        .clipShape(RoundedRectangle(cornerRadius: 16))
                                    if message.role != "user" { Spacer(minLength: 36) }
                                }
                            }
                            if sending { HStack { ProgressView(); Text("AI 正在回复…").foregroundStyle(.secondary) }; }
                        }.padding()
                    }
                }
                Divider()
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("发送消息…", text: $input, axis: .vertical)
                        .lineLimit(1...5).focused($focused)
                        .padding(10)
                        .background(.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                    }.disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                }.padding()
            }
            .navigationTitle("AI")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { messages.removeAll(); error = nil } label: { Image(systemName: "plus") }
                        .accessibilityLabel("新对话")
                }
            }
            .alert("AI 请求失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { }
            } message: { Text(error ?? "") }
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        focused = false
        messages.append(AIChatMessage(role: "user", content: text))
        sending = true
        Task {
            do {
                let answer = try await FlyMailAI.chat(messages: messages)
                await MainActor.run { messages.append(AIChatMessage(role: "assistant", content: answer)); sending = false }
            } catch {
                await MainActor.run { error = error.localizedDescription; sending = false }
            }
        }
    }
}