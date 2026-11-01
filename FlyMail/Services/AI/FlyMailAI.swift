import Foundation

struct AIChatMessage: Identifiable, Codable {
    let id = UUID()
    var role: String
    var content: String
}

enum FlyMailAI {
    static var baseURL: String { UserDefaults.standard.string(forKey: "ai.baseURL") ?? "https://api.openai.com/v1" }
    static var model: String { UserDefaults.standard.string(forKey: "ai.model") ?? "" }
    static var apiKey: String { KeychainStore.get("ai.apiKey") ?? "" }

    static func chat(messages: [AIChatMessage]) async throws -> String {
        guard !apiKey.isEmpty else { throw AIError.missingKey }
        guard !model.isEmpty else { throw AIError.missingModel }
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
            case .missingKey: "请先在设置中填写 API Key"
            case .missingModel: "请先在设置中填写模型名称"
            case .badURL: "API Base URL 格式不正确"
            case .invalidResponse: "服务返回了无效响应"
            case .empty: "模型没有返回内容"
            case .server(let s): s
            }
        }
    }
}