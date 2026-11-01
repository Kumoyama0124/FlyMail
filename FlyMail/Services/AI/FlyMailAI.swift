import Foundation

struct AIChatAttachment: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var fileName: String
    var mimeType: String
    var localPath: String

    var isImage: Bool { mimeType.lowercased().hasPrefix("image/") }
}

struct AIChatMessage: Identifiable, Codable {
    var id: UUID
    var role: String
    var content: String
    var attachments: [AIChatAttachment]

    init(
        id: UUID = UUID(),
        role: String,
        content: String,
        attachments: [AIChatAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
    }
}

struct AIConversation: Identifiable, Codable {
    var id: String = UUID().uuidString
    var title: String
    var messages: [AIChatMessage] = []
    var updatedAt: Date = .now
}

enum AIConversationStore {
    private static let key = "ai.conversations.v1"

    static func load() -> [AIConversation] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([AIConversation].self, from: data) else {
            return []
        }
        return items.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func save(_ conversations: [AIConversation]) {
        let sorted = conversations.sorted { $0.updatedAt > $1.updatedAt }.prefix(100)
        guard let data = try? JSONEncoder().encode(Array(sorted)) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum AIChatAttachmentStore {
    static func save(data: Data, fileName: String, mimeType: String) throws -> AIChatAttachment {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlyMail/AIChatAttachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = URL(fileURLWithPath: fileName).pathExtension
        let fileURL = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext.isEmpty ? "bin" : ext)
        try data.write(to: fileURL, options: .atomic)
        return AIChatAttachment(fileName: fileName, mimeType: mimeType, localPath: fileURL.path)
    }

    static func data(for attachment: AIChatAttachment) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: attachment.localPath))
    }
}

enum AIReasoningLevel: String, CaseIterable, Identifiable, Codable {
    case off
    case low
    case medium
    case high
    case max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "关闭"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .max: "最高"
        }
    }

    var detail: String {
        switch self {
        case .off: "优先速度与较低成本"
        case .low: "轻量推理"
        case .medium: "均衡推理"
        case .high: "深入推理"
        case .max: "最大推理强度"
        }
    }
}

enum AIProvider: String, CaseIterable, Identifiable {
    case openAI = "ChatGPT"
    case claude = "Claude"
    case gemini = "Gemini"
    case zhipu = "智谱 GLM"
    case qwen = "通义千问"
    case kimi = "Kimi"
    case deepSeek = "DeepSeek"
    case custom = "自定义"

    var id: String { rawValue }

    var baseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .claude: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .zhipu: "https://open.bigmodel.cn/api/paas/v4"
        case .qwen: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .kimi: "https://api.moonshot.cn/v1"
        case .deepSeek: "https://api.deepseek.com/v1"
        case .custom: ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: "gpt-4.1-mini"
        case .claude: "claude-sonnet-4-20250514"
        case .gemini: "gemini-2.5-flash"
        case .zhipu: "glm-4.5-air"
        case .qwen: "qwen-plus"
        case .kimi: "kimi-k2.6"
        case .deepSeek: "deepseek-v4-flash"
        case .custom: ""
        }
    }

    var usesAnthropicAPI: Bool { self == .claude }
    var usesGeminiAPI: Bool { self == .gemini }
}

struct AIModelProfile: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var providerRaw: String
    var baseURL: String
    var model: String
    var isFallback: Bool
    var reasoningDefaultRaw: String

    var provider: AIProvider { AIProvider(rawValue: providerRaw) ?? .custom }
    var reasoningDefault: AIReasoningLevel { AIReasoningLevel(rawValue: reasoningDefaultRaw) ?? .off }

    init(
        id: String = UUID().uuidString,
        name: String,
        providerRaw: String,
        baseURL: String,
        model: String,
        isFallback: Bool = false,
        reasoningDefaultRaw: String = AIReasoningLevel.off.rawValue
    ) {
        self.id = id
        self.name = name
        self.providerRaw = providerRaw
        self.baseURL = baseURL
        self.model = model
        self.isFallback = isFallback
        self.reasoningDefaultRaw = reasoningDefaultRaw
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, providerRaw, baseURL, model, isFallback, reasoningDefaultRaw
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        providerRaw = try values.decode(String.self, forKey: .providerRaw)
        baseURL = try values.decode(String.self, forKey: .baseURL)
        model = try values.decode(String.self, forKey: .model)
        isFallback = try values.decodeIfPresent(Bool.self, forKey: .isFallback) ?? false
        reasoningDefaultRaw = try values.decodeIfPresent(String.self, forKey: .reasoningDefaultRaw) ?? AIReasoningLevel.off.rawValue
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(providerRaw, forKey: .providerRaw)
        try values.encode(baseURL, forKey: .baseURL)
        try values.encode(model, forKey: .model)
        try values.encode(isFallback, forKey: .isFallback)
        try values.encode(reasoningDefaultRaw, forKey: .reasoningDefaultRaw)
    }

    static func makeDefault() -> AIModelProfile {
        let provider = AIProvider.openAI
        return AIModelProfile(
            name: provider.rawValue,
            providerRaw: provider.rawValue,
            baseURL: provider.baseURL,
            model: provider.defaultModel
        )
    }
}

enum AIModelStore {
    private static let profilesKey = "ai.profiles.v1"
    private static let primaryKey = "ai.primaryProfileID"
    private static let translationKey = "ai.translationProfileID"
    private static let migrationKey = "ai.legacyProfileMigrated"

    static func keychainKey(for profileID: String) -> String {
        "ai.profile.\(profileID).apiKey"
    }

    static var primaryProfileID: String {
        UserDefaults.standard.string(forKey: primaryKey) ?? ""
    }

    static func setPrimaryProfileID(_ id: String) {
        UserDefaults.standard.set(id, forKey: primaryKey)
    }

    static var translationProfileID: String {
        UserDefaults.standard.string(forKey: translationKey) ?? ""
    }

    static func setTranslationProfileID(_ id: String) {
        UserDefaults.standard.set(id, forKey: translationKey)
    }

    static func loadProfiles() -> [AIModelProfile] {
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let profiles = try? JSONDecoder().decode([AIModelProfile].self, from: data) {
            return profiles
        }
        return migrateLegacyConfiguration()
    }

    static func saveProfiles(_ profiles: [AIModelProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: profilesKey)
    }

    private static func migrateLegacyConfiguration() -> [AIModelProfile] {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return [] }

        let oldProviderRaw = defaults.string(forKey: "ai.provider")
        let provider = AIProvider(rawValue: oldProviderRaw ?? "") ?? .openAI
        let oldModel = defaults.string(forKey: "ai.model") ?? ""
        let oldBaseURL = defaults.string(forKey: "ai.baseURL") ?? ""
        let oldKey = KeychainStore.get("ai.apiKey") ?? ""

        guard !oldKey.isEmpty || !oldModel.isEmpty || !oldBaseURL.isEmpty || oldProviderRaw != nil else {
            defaults.set(true, forKey: migrationKey)
            return []
        }

        let profile = AIModelProfile(
            name: provider.rawValue,
            providerRaw: provider.rawValue,
            baseURL: oldBaseURL.isEmpty ? provider.baseURL : oldBaseURL,
            model: oldModel.isEmpty ? provider.defaultModel : oldModel
        )
        saveProfiles([profile])
        setPrimaryProfileID(profile.id)
        if !oldKey.isEmpty {
            KeychainStore.set(oldKey, for: keychainKey(for: profile.id))
            KeychainStore.delete("ai.apiKey")
        }
        defaults.set(true, forKey: migrationKey)
        return [profile]
    }
}

enum AIMemoryStore {
    static let enabledKey = "ai.memory.enabled"
    private static let summaryKey = "ai.memory.summary"
    private static let compactedCountKey = "ai.memory.compactedCount"
    private static let compactedConversationKey = "ai.memory.compactedConversationID"

    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var summary: String {
        UserDefaults.standard.string(forKey: summaryKey) ?? ""
    }

    static var compactedCount: Int {
        UserDefaults.standard.integer(forKey: compactedCountKey)
    }

    static var compactedConversationID: String {
        UserDefaults.standard.string(forKey: compactedConversationKey) ?? ""
    }

    static func saveSummary(_ value: String, compactedCount: Int, conversationID: String) {
        UserDefaults.standard.set(value, forKey: summaryKey)
        UserDefaults.standard.set(compactedCount, forKey: compactedCountKey)
        UserDefaults.standard.set(conversationID, forKey: compactedConversationKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: summaryKey)
        UserDefaults.standard.removeObject(forKey: compactedCountKey)
        UserDefaults.standard.removeObject(forKey: compactedConversationKey)
    }
}

enum AIPersonalization {
    static let nameKey = "ai.persona.name"
    static let languageKey = "ai.persona.language"
    static let toneKey = "ai.persona.tone"
    static let instructionKey = "ai.persona.instruction"
    static let enterToSendKey = "ai.chat.enterToSend"

    static var systemPrompt: String {
        let defaults = UserDefaults.standard
        let name = defaults.string(forKey: nameKey) ?? "FlyMail 助手"
        let language = defaults.string(forKey: languageKey) ?? "auto"
        let tone = defaults.string(forKey: toneKey) ?? "natural"
        let instruction = defaults.string(forKey: instructionKey) ?? ""

        let languageInstruction: String
        switch language {
        case "zh-Hans": languageInstruction = "请始终使用简体中文回复。"
        case "en": languageInstruction = "Please reply in English."
        default: languageInstruction = "跟随用户当前使用的语言回复。"
        }

        let toneInstruction: String
        switch tone {
        case "concise": toneInstruction = "表达简洁，先给结论，再补充必要细节。"
        case "professional": toneInstruction = "保持专业、严谨、清晰，避免随意猜测。"
        case "friendly": toneInstruction = "语气友好自然，耐心解释，但不要过度寒暄。"
        case "detailed": toneInstruction = "解释充分，结构清楚，必要时提供步骤和例子。"
        default: toneInstruction = "语气自然、可靠，内容清楚且不过度冗长。"
        }

        let customInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = [
            "你是\(name)，FlyMail 内置的 AI 助手。擅长日常问答、理解邮件、摘要、翻译和写作。",
            "回答必须准确；不确定时明确说明，不要编造信息。",
            languageInstruction,
            toneInstruction
        ]
        if !customInstruction.isEmpty {
            parts.append("用户补充的个性化要求：\n\(customInstruction)")
        }
        if AIMemoryStore.isEnabled, !AIMemoryStore.summary.isEmpty {
            parts.append("从之前对话中提炼的长期记忆（只作为上下文参考；如与用户本轮新信息冲突，以本轮为准）：\n\(AIMemoryStore.summary)")
        }
        return parts.joined(separator: "\n\n")
    }
}

enum FlyMailAI {
    static var hasReadyModel: Bool {
        let profiles = AIModelStore.loadProfiles()
        return profiles.contains {
            !$0.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !(KeychainStore.get(AIModelStore.keychainKey(for: $0.id)) ?? "").isEmpty
        }
    }

    static func primaryProfile() -> AIModelProfile? {
        let profiles = AIModelStore.loadProfiles()
        return profiles.first(where: { $0.id == AIModelStore.primaryProfileID }) ?? profiles.first
    }

    static func canControlReasoning(_ profile: AIModelProfile) -> Bool {
        let model = profile.model.lowercased()
        switch profile.provider {
        case .openAI:
            return model.hasPrefix("gpt-5") || model.hasPrefix("gpt-6") ||
                model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4")
        case .claude:
            return model.contains("3-7") || model.contains("4-") || model.contains("opus-5") || model.contains("sonnet-5")
        case .gemini:
            return model.contains("2.5") || model.contains("gemini-3") || model.contains("gemini-4")
        case .zhipu:
            return model.contains("glm-5.2") || model.contains("glm-5.3")
        case .qwen:
            return model.contains("qwen3")
        case .kimi:
            return model.contains("k2.5") || model.contains("k2.6")
        case .deepSeek:
            return model.contains("deepseek-v4") || model.contains("deepseek-v3.2")
        case .custom:
            return false
        }
    }

    /// 主模型优先；主模型失败时，按设置列表中的顺序尝试已启用的备用模型。
    static func chat(
        messages: [AIChatMessage],
        profileID: String? = nil,
        reasoning: AIReasoningLevel? = nil
    ) async throws -> String {
        let profiles = AIModelStore.loadProfiles()
        guard !profiles.isEmpty else { throw AIError.noProfiles }

        if let profileID, let selected = profiles.first(where: { $0.id == profileID }) {
            let key = KeychainStore.get(AIModelStore.keychainKey(for: selected.id)) ?? ""
            return try await chat(profile: selected, apiKey: key, messages: messages, reasoning: reasoning)
        }

        let primaryID = AIModelStore.primaryProfileID
        let primary = profiles.first(where: { $0.id == primaryID }) ?? profiles[0]
        let fallbacks = profiles.filter { $0.id != primary.id && $0.isFallback }
        let ordered = [primary] + fallbacks

        var failures: [String] = []
        var hadUsableKey = false

        for profile in ordered {
            let key = KeychainStore.get(AIModelStore.keychainKey(for: profile.id)) ?? ""
            guard !key.isEmpty else {
                failures.append("\(profile.name)：未配置 API Key")
                continue
            }
            hadUsableKey = true
            do {
                return try await chat(profile: profile, apiKey: key, messages: messages, reasoning: reasoning)
            } catch {
                failures.append("\(profile.name)：\(error.localizedDescription)")
            }
        }

        if !hadUsableKey { throw AIError.missingKey }
        throw AIError.allModelsFailed(failures.joined(separator: "\n"))
    }

    static func compactMemory(messages: [AIChatMessage]) async throws -> String {
        guard let profile = primaryProfile() else { throw AIError.noProfiles }
        let key = KeychainStore.get(AIModelStore.keychainKey(for: profile.id)) ?? ""
        let prompt = """
        请把下面的历史对话提炼成一份可长期使用的简短记忆，供后续聊天作为背景上下文。
        只保留稳定的用户偏好、长期项目、已确认的事实、重要决定和未完成事项。
        删除寒暄、临时问题、重复内容和过时信息；不要写入密码、API Key、令牌、验证码或其他秘密。
        使用简体中文，按主题分组，控制在 1200 个汉字以内。只输出整理后的记忆正文。
        """
        let source = messages.map { "\($0.role == "user" ? "用户" : "助手")：\($0.content)" }
            .joined(separator: "\n\n")
        return try await chat(
            profile: profile,
            apiKey: key,
            messages: [
                AIChatMessage(role: "system", content: prompt),
                AIChatMessage(role: "user", content: source)
            ],
            reasoning: .off,
            includeMemory: false
        )
    }

    /// 设置页连接测试使用指定配置，不触发其他模型的回退。
    static func chat(
        profile: AIModelProfile,
        apiKey: String,
        messages: [AIChatMessage],
        reasoning: AIReasoningLevel? = nil,
        includeMemory: Bool = true
    ) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIError.missingKey }
        guard !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.missingModel
        }

        var requestMessages = messages
        if includeMemory {
            let prompt = AIPersonalization.systemPrompt
            if let systemIndex = requestMessages.firstIndex(where: { $0.role == "system" }) {
                requestMessages[systemIndex].content = prompt + "\n\n" + requestMessages[systemIndex].content
            } else {
                requestMessages.insert(AIChatMessage(role: "system", content: prompt), at: 0)
            }
        }

        let level = reasoning ?? profile.reasoningDefault
        if profile.provider.usesAnthropicAPI {
            return try await claudeChat(profile: profile, apiKey: key, messages: requestMessages, reasoning: level)
        }
        if profile.provider.usesGeminiAPI {
            return try await geminiChat(profile: profile, apiKey: key, messages: requestMessages, reasoning: level)
        }
        return try await compatibleChat(profile: profile, apiKey: key, messages: requestMessages, reasoning: level)
    }

    private static func endpoint(baseURL: String, path: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty else { throw AIError.badURL }
        let endpointString = normalized.hasSuffix(path) ? normalized : normalized + path
        guard let url = URL(string: endpointString), url.scheme != nil, url.host != nil else {
            throw AIError.badURL
        }
        return url
    }

    private static func messageText(_ message: AIChatMessage) -> String {
        let names = message.attachments.filter { !$0.isImage }.map { "[附件：\($0.fileName)]" }
        return ([message.content] + names).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func openAIContent(_ message: AIChatMessage) -> Any {
        let images = message.attachments.filter(\.isImage)
        guard !images.isEmpty else { return messageText(message) }
        var parts: [[String: Any]] = []
        parts.append(["type": "text", "text": messageText(message)])
        for attachment in images {
            guard let data = AIChatAttachmentStore.data(for: attachment) else { continue }
            let url = "data:\(attachment.mimeType);base64,\(data.base64EncodedString())"
            parts.append(["type": "image_url", "image_url": ["url": url]])
        }
        return parts
    }

    private static func claudeContent(_ message: AIChatMessage) -> [[String: Any]] {
        var parts: [[String: Any]] = [["type": "text", "text": messageText(message)]]
        for attachment in message.attachments where attachment.isImage {
            guard let data = AIChatAttachmentStore.data(for: attachment) else { continue }
            parts.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": attachment.mimeType,
                    "data": data.base64EncodedString()
                ]
            ])
        }
        return parts
    }

    private static func compatibleChat(
        profile: AIModelProfile,
        apiKey: String,
        messages: [AIChatMessage],
        reasoning: AIReasoningLevel
    ) async throws -> String {
        let url = try endpoint(baseURL: profile.baseURL, path: "/chat/completions")
        var body: [String: Any] = [
            "model": profile.model,
            "messages": messages.map { ["role": $0.role, "content": openAIContent($0)] }
        ]
        addReasoningParameters(to: &body, profile: profile, level: reasoning)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw AIError.server("HTTP \(http.statusCode)：\(String(bodyText.prefix(600)))")
        }
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw AIError.empty
        }
        return text
    }

    private static func addReasoningParameters(
        to body: inout [String: Any],
        profile: AIModelProfile,
        level: AIReasoningLevel
    ) {
        guard canControlReasoning(profile) else { return }
        let model = profile.model.lowercased()

        switch profile.provider {
        case .openAI:
            body["reasoning_effort"] = level.rawValue == "max" ? "xhigh" : level.rawValue
        case .deepSeek:
            if level == .off {
                body["thinking"] = ["type": "disabled"]
                body["reasoning_effort"] = "none"
            } else {
                body["thinking"] = ["type": "enabled"]
                body["reasoning_effort"] = level == .medium || level == .low ? "low" : (level == .max ? "max" : "high")
            }
        case .zhipu:
            if model.contains("glm-5.3") {
                body["thinking"] = ["type": "enabled", "clear_thinking": false]
                body["reasoning_effort"] = level == .off || level == .low ? "low" : (level == .medium ? "high" : "max")
            } else if level == .off || level == .low || level == .medium {
                body["thinking"] = ["type": level == .off ? "disabled" : "enabled", "clear_thinking": false]
                if model.contains("glm-5.2") {
                    body["reasoning_effort"] = level == .off ? "none" : "high"
                }
            } else {
                body["thinking"] = ["type": "enabled", "clear_thinking": false]
                body["reasoning_effort"] = level == .max ? "max" : "high"
            }
        case .qwen:
            if model.contains("qwen3.8") {
                if level == .off {
                    body["enable_thinking"] = false
                } else {
                    body["enable_thinking"] = true
                    body["reasoning_effort"] = level == .low ? "low" : (level == .medium ? "medium" : "xhigh")
                }
            } else {
                body["enable_thinking"] = level != .off
                if level != .off {
                    body["thinking_budget"] = level == .low ? 4096 : (level == .medium ? 8192 : 16384)
                }
            }
        case .kimi:
            if model.contains("k2.6") {
                body["thinking"] = ["type": level == .off ? "disabled" : "enabled", "keep": "all"]
            } else {
                body["thinking"] = ["type": level == .off ? "disabled" : "enabled"]
            }
        case .claude, .gemini, .custom:
            break
        }
    }

    private static func claudeChat(
        profile: AIModelProfile,
        apiKey: String,
        messages: [AIChatMessage],
        reasoning: AIReasoningLevel
    ) async throws -> String {
        let url = try endpoint(baseURL: profile.baseURL, path: "/messages")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let system = messages.first(where: { $0.role == "system" })?.content
        let turns = messages.filter { $0.role != "system" }.map {
            ["role": $0.role, "content": claudeContent($0)]
        }
        var body: [String: Any] = ["model": profile.model, "max_tokens": 8192, "messages": turns]
        if let system, !system.isEmpty { body["system"] = system }

        if reasoning != .off, canControlReasoning(profile) {
            let model = profile.model.lowercased()
            if model.contains("4-6") || model.contains("4-7") || model.contains("4-8") ||
                model.contains("opus-5") || model.contains("sonnet-5") {
                body["thinking"] = ["type": "adaptive"]
                body["output_config"] = ["effort": reasoning == .max ? "high" : reasoning.rawValue]
            } else {
                let budget = reasoning == .low ? 1024 : (reasoning == .medium ? 4096 : (reasoning == .high ? 8192 : 12000))
                body["thinking"] = ["type": "enabled", "budget_tokens": budget]
                body["max_tokens"] = max(8192, budget + 4096)
            }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw AIError.server("HTTP \(http.statusCode)：\(String(bodyText.prefix(600)))")
        }
        let decoded = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        let text = decoded.content.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
        guard !text.isEmpty else { throw AIError.empty }
        return text
    }

    private static func geminiChat(
        profile: AIModelProfile,
        apiKey: String,
        messages: [AIChatMessage],
        reasoning: AIReasoningLevel
    ) async throws -> String {
        let model = profile.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? profile.model
        var root = profile.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if root.hasSuffix("/openai") { root.removeLast("/openai".count) }
        if !root.hasSuffix("/v1beta") { root += "/v1beta" }
        guard let url = URL(string: root + "/models/\(model):generateContent") else {
            throw AIError.badURL
        }

        let system = messages.first(where: { $0.role == "system" })?.content
        let contents: [[String: Any]] = messages.filter { $0.role != "system" }.map { message in
            var parts: [[String: Any]] = []
            parts.append(["text": messageText(message)])
            for attachment in message.attachments where attachment.isImage {
                if let data = AIChatAttachmentStore.data(for: attachment) {
                    parts.append(["inlineData": ["mimeType": attachment.mimeType, "data": data.base64EncodedString()]])
                }
            }
            return ["role": message.role == "assistant" ? "model" : "user", "parts": parts]
        }

        var body: [String: Any] = ["contents": contents]
        if let system, !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }

        if canControlReasoning(profile) {
            var thinking: [String: Any] = [:]
            if profile.model.lowercased().contains("2.5") {
                // Gemini 2.5 Flash 可通过 0 关闭思考；2.5 Pro 不支持完全关闭。
                if profile.model.lowercased().contains("pro") && reasoning == .off {
                    thinking["thinkingBudget"] = 128
                } else {
                    let budget = reasoning == .off ? 0 : (reasoning == .low ? 1024 : (reasoning == .medium ? 8192 : (reasoning == .high ? 16384 : 24576)))
                    thinking["thinkingBudget"] = budget
                }
            } else {
                let level: String
                switch reasoning {
                case .off: level = "MINIMAL"
                case .low: level = "LOW"
                case .medium: level = "MEDIUM"
                case .high, .max: level = "HIGH"
                }
                thinking["thinkingLevel"] = level
            }
            body["generationConfig"] = ["thinkingConfig": thinking]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw AIError.server("HTTP \(http.statusCode)：\(String(bodyText.prefix(600)))")
        }
        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        let text = decoded.candidates.first?.content.parts.compactMap(\.text).joined(separator: "\n") ?? ""
        guard !text.isEmpty else { throw AIError.empty }
        return text
    }

    private struct ClaudeResponse: Decodable {
        struct Content: Decodable { let type: String; let text: String? }
        let content: [Content]
    }

    private struct GeminiResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String? }
                let parts: [Part]
            }
            let content: Content
        }
        let candidates: [Candidate]
    }

    private struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    enum AIError: LocalizedError {
        case noProfiles
        case missingKey
        case missingModel
        case badURL
        case invalidResponse
        case empty
        case server(String)
        case allModelsFailed(String)

        var errorDescription: String? {
            switch self {
            case .noProfiles: "尚未添加 AI 模型，请前往「设置 → AI」添加模型。"
            case .missingKey: "所选模型没有配置 API Key，请检查「设置 → AI」。"
            case .missingModel: "请先填写模型名称。"
            case .badURL: "API Base URL 格式不正确，请检查地址。"
            case .invalidResponse: "服务没有返回有效的 HTTP 响应。"
            case .empty: "模型没有返回内容。"
            case .server(let message): message
            case .allModelsFailed(let details): "所有可用模型均请求失败：\n\(details)"
            }
        }
    }
}
