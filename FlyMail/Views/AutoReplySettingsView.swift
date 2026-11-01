import SwiftUI

/// 自动回复设置：一个独立的"邮箱 AI 伙伴"人设，默认关闭。
/// 人设与 AI 设置里的系统助手相互独立；开关打开后才会在收到新邮件时自动回复。
struct AutoReplySettingsView: View {
    @State private var enabled = AutoReplyStore.isEnabled
    @State private var name = AutoReplyStore.personaName
    @State private var tone = AutoReplyStore.personaTone
    @State private var instruction = AutoReplyStore.personaInstruction

    var body: some View {
        Form {
            Section {
                Toggle("启用自动回复", isOn: $enabled)
            } header: {
                Text("开关")
            } footer: {
                Text("默认关闭。开启后，收到新邮件时 AI 会以下面配置的“邮箱伙伴”人设自动回复，并表明自己是 AI、不冒充你本人。安全限制：跳过验证码/广告/系统机器人邮件；每个发件人每天最多回复 3 条、两次至少间隔 30 分钟。使用首选模型，会产生 API 用量。")
            }

            Section {
                TextField("伙伴名称（默认：小 Fly）", text: $name)
                    .textInputAutocapitalization(.never)
                Picker("性格", selection: $tone) {
                    Text("自然友好").tag("friendly")
                    Text("幽默风趣").tag("humorous")
                    Text("温暖贴心").tag("warm")
                    Text("正式礼貌").tag("formal")
                    Text("高冷话少").tag("cool")
                    Text("极简短句").tag("minimal")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("专属人设指令")
                        .font(.subheadline.weight(.medium))
                    TextEditor(text: $instruction)
                        .frame(minHeight: 110)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    Text("例如：喜欢用 emoji、自称什么昵称、聊到什么话题要多聊两句、绝对不聊什么。只作用于自动回复，不影响 AI 对话里的助手。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("人设（与系统助手相互独立）")
            } footer: {
                Text("这个人设只在自动回复里生效；AI 对话、邮件摘要等功能仍使用 AI 设置里的助手配置。")
            }

            Section {
                Label("回复会标明是 AI 自动回复，不冒充本人", systemImage: "checkmark.shield")
                Label("不回验证码、广告、系统机器人邮件", systemImage: "checkmark.shield")
                Label("不替你承诺付款、发验证码等敏感内容", systemImage: "checkmark.shield")
            } header: {
                Text("安全边界")
            } footer: {
                Text("建议搭配一个便宜、限量的首选模型使用，避免意外消耗额度。")
            }
        }
        .navigationTitle("自动回复")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: enabled) { _, newValue in
            AutoReplyStore.saveEnabled(newValue)
        }
        .onChange(of: name) { _, _ in persistPersona() }
        .onChange(of: tone) { _, _ in persistPersona() }
        .onChange(of: instruction) { _, _ in persistPersona() }
    }

    private func persistPersona() {
        AutoReplyStore.savePersona(name: name, tone: tone, instruction: instruction)
    }
}
