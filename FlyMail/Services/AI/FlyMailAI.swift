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
        case .custom: UserDefaults.standard.string(forKey: "ai.baseURL") ?? ""
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
        case .custom: UserDefaults.standard.string(forKey: "ai.model") ?? ""
        }
    }

    var usesOpenAICompatibleAPI: Bool { self != .claude && self != .custom }
}

enum FlyMailAI {
    static var provider: AIProvider {
        AIProvider(rawValue: UserDefaults.standard.string(forKey: "ai.provider") ?? "") ?? .openAI
    }
    static var baseURL: String {
        provider == .custom ? (UserDefaults.standard.string(forKey: "ai.baseURL") ?? "") : provider.baseURL
    }
    static var model: String {
        let custom = UserDefaults.standard.string(forKey: "ai.model") ?? ""
        return provider == .custom ? custom : (custom.isEmpty ? provider.defaultModel : custom)
    }
    static var apiKey: String { KeychainStore.get("ai.apiKey") ?? "" }

    static func chat(messages: [AIChatMessage]) async throws -> String {
        guard !apiKey.isEmpty else { throw AIError.missingKey }
        guard !model.isEmpty else { throw AIError.missingModel }
        if provider == .claude { return try await claudeChat(messages: messages) }
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/chat/completions") else { throw AIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": 0.7
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AIError.server("HTTP \(http.statusCode): \(String(text.prefix(300)))")
        }
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else { throw AIError.empty }
        return text
    }

    private static func claudeChat(messages: [AIChatMessage]) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw AIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let system = messages.first(where: { $0.role == "system" })?.content
        let turns = messages.filter { $0.role != "system" }.map { ["role": $0.role, "content": $0.content] }
        var body: [String: Any] = ["model": model, "max_tokens": 4096, "messages": turns]
        if let system, !system.isEmpty { body["system"] = system }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.server("HTTP \(http.statusCode): \(String(String(data: data, encoding: .utf8) ?? "").prefix(300))")
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
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }

    enum AIError: LocalizedError {
        case missingKey, missingModel, badURL, invalidResponse, empty
        case server(String)
        var errorDescription: String? {
            switch self {
            case .missingKey: "请先填写 API Key"
            case .missingModel: "请先填写模型名称"
            case .badURL: "API 地址格式不正确"
            case .invalidResponse: "服务返回了无效响应"
            case .empty: "模型没有返回内容"
            case .server(let s): s
            }
        }
    }
}
