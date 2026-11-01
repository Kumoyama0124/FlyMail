import Foundation

struct AIChatMessage: Identifiable, Codable {
    let id = UUID()
    var role: String
    var content: String
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
        case .kimi: "kimi-k2-0711-preview"
        case .deepSeek: "deepseek-chat"
        case .custom: ""
        }
    }

    var usesAnthropicAPI: Bool { self == .claude }
}

struct AIModelProfile: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var providerRaw: String
    var baseURL: String
    var model: String
    var isFallback: Bool

    var provider: AIProvider { AIProvider(rawValue: providerRaw) ?? .custom }

    init(
        id: String = UUID().uuidString,
        name: String,
        providerRaw: String,
        baseURL: String,
        model: String,
        isFallback: Bool = false
    ) {
        self.id = id
        self.name = name
        self.providerRaw = providerRaw
        self.baseURL = baseURL
        self.model = model
        self.isFallback = isFallback
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

enum AIPersonalization {
    static let nameKey = "ai.persona.name"
    static let languageKey = "ai.persona.language"
    static let toneKey = "ai.persona.tone"
    static let instructionKey = "ai.persona.instruction"

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
        return [
            "你是\(name)，FlyMail 内置的 AI 助手。擅长日常问答、理解邮件、摘要、翻译和写作。",
            "回答必须准确；不确定时明确说明，不要编造信息。",
            languageInstruction,
            toneInstruction,
            customInstruction.isEmpty ? nil : "用户补充的个性化要求：\n\(customInstruction)"
        ].compactMap { $0 }.joined(separator: "\n\n")
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

    /// 主模型优先；主模型失败时，按设置列表中的顺序尝试已启用的备用模型。
    static func chat(messages: [AIChatMessage]) async throws -> String {
        let profiles = AIModelStore.loadProfiles()
        guard !profiles.isEmpty else { throw AIError.noProfiles }

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
                return try await chat(profile: profile, apiKey: key, messages: messages)
            } catch {
                failures.append("\(profile.name)：\(error.localizedDescription)")
            }
        }

        if !hadUsableKey { throw AIError.missingKey }
        throw AIError.allModelsFailed(failures.joined(separator: "\n"))
    }

    /// 设置页连接测试使用指定配置，不触发其他模型的回退。
    static func chat(profile: AIModelProfile, apiKey: String, messages: [AIChatMessage]) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIError.missingKey }
        guard !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.missingModel
        }

        var requestMessages = messages
        let systemPrompt = AIPersonalization.systemPrompt
        if let systemIndex = requestMessages.firstIndex(where: { $0.role == "system" }) {
            requestMessages[systemIndex].content = systemPrompt + "\n\n" + requestMessages[systemIndex].content
        } else {
            requestMessages.insert(AIChatMessage(role: "system", content: systemPrompt), at: 0)
        }

        if profile.provider.usesAnthropicAPI {
            return try await claudeChat(profile: profile, apiKey: key, messages: requestMessages)
        }
        return try await compatibleChat(profile: profile, apiKey: key, messages: requestMessages)
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

    private static func compatibleChat(profile: AIModelProfile, apiKey: String, messages: [AIChatMessage]) async throws -> String {
        let url = try endpoint(baseURL: profile.baseURL, path: "/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": profile.model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": 0.7
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIError.server("HTTP \(http.statusCode)：\(String(body.prefix(500)))")
        }
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw AIError.empty
        }
        return text
    }

    private static func claudeChat(profile: AIModelProfile, apiKey: String, messages: [AIChatMessage]) async throws -> String {
        let url = try endpoint(baseURL: profile.baseURL, path: "/messages")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let system = messages.first(where: { $0.role == "system" })?.content
        let turns = messages.filter { $0.role != "system" }.map {
            ["role": $0.role, "content": $0.content]
        }
        var body: [String: Any] = ["model": profile.model, "max_tokens": 4096, "messages": turns]
        if let system, !system.isEmpty { body["system"] = system }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIError.server("HTTP \(http.statusCode)：\(String(body.prefix(500)))")
        }
        let decoded = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        let text = decoded.content.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
        guard !text.isEmpty else { throw AIError.empty }
        return text
    }

    private struct ClaudeResponse: Decodable {
        struct Content: Decodable { let type: String; let text: String? }
        let content: [Content]
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
            case .missingKey: "主模型和备用模型都没有可用的 API Key，请检查「设置 → AI」。"
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
