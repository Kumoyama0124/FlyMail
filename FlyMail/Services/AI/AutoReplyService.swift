import Foundation
import SwiftData

/// 自动回复（默认关闭）：一个独立的"邮箱 AI 伙伴"人设，收到新邮件时自动回复。
/// 与系统助手（AIPersonalization）相互独立——人设、语气、指令都是自己的配置；
/// 只在用户明确打开开关后工作，且带完整的防循环与频率限制。
enum AutoReplyStore {
    static let enabledKey = "ai.autoreply.enabled"
    static let nameKey = "ai.autoreply.persona.name"
    static let toneKey = "ai.autoreply.persona.tone"
    static let instructionKey = "ai.autoreply.persona.instruction"
    static let respondedKey = "ai.autoreply.responded.v1"   // 已回复过的 messageID 集合
    static let rateKey = "ai.autoreply.rate.v1"              // [发件人邮箱: [发送时间戳]]

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }
    static var personaName: String {
        UserDefaults.standard.string(forKey: nameKey) ?? ""
    }
    static var personaTone: String {
        UserDefaults.standard.string(forKey: toneKey) ?? "friendly"
    }
    static var personaInstruction: String {
        UserDefaults.standard.string(forKey: instructionKey) ?? ""
    }

    static func saveEnabled(_ on: Bool) { UserDefaults.standard.set(on, forKey: enabledKey) }
    static func savePersona(name: String, tone: String, instruction: String) {
        UserDefaults.standard.set(name, forKey: nameKey)
        UserDefaults.standard.set(tone, forKey: toneKey)
        UserDefaults.standard.set(instruction, forKey: instructionKey)
    }

    static var toneTitle: String {
        switch personaTone {
        case "humorous": "幽默风趣"
        case "warm": "温暖贴心"
        case "formal": "正式礼貌"
        case "cool": "高冷话少"
        case "minimal": "极简短句"
        default: "自然友好"
        }
    }

    static func respondedIDs() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: respondedKey),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    static func markResponded(_ messageID: String) {
        guard let data = UserDefaults.standard.data(forKey: respondedKey),
              var list = try? JSONDecoder().decode([String].self, from: data) else {
            if let data = try? JSONEncoder().encode([messageID]) {
                UserDefaults.standard.set(data, forKey: respondedKey)
            }
            return
        }
        list.append(messageID)
        if list.count > 2000 { list.removeFirst(list.count - 2000) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: respondedKey)
        }
    }

    static func recentSendTimes(for sender: String) -> [Date] {
        guard let data = UserDefaults.standard.data(forKey: rateKey),
              let all = try? JSONDecoder().decode([String: [Date]].self, from: data) else { return [] }
        return all[sender] ?? []
    }

    static func recordSend(to sender: String) {
        guard let data = UserDefaults.standard.data(forKey: rateKey),
              var all = try? JSONDecoder().decode([String: [Date]].self, from: data) else {
            let fresh = [sender: [Date.now]]
            if let data = try? JSONEncoder().encode(fresh) { UserDefaults.standard.set(data, forKey: rateKey) }
            return
        }
        var times = (all[sender] ?? []).filter { $0 > Date.now.addingTimeInterval(-24 * 3600) }
        times.append(.now)
        all[sender] = times
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: rateKey) }
    }

    /// 独立人设的系统提示词：与系统助手完全分开
    static func personaSystemPrompt() -> String {
        let name = personaName.isEmpty ? “小 Fly” : personaName
        var parts = [
            “你是「\(name)」，用户邮箱里的 AI 伙伴，替用户自动回复新收到的邮件。”,
            “写作要求：回复开头用一句自然的话说明这是一条自动回复（比如“我是 \(name)，这个邮箱的 AI 伙伴”），不冒充用户本人；正文简短（一般不超过 120 字）、口语化、符合你的性格（\(toneTitle)）；对方写英文时可以用英文回复。”,
            “安全底线：不替用户承诺付款、转账、签署合同或透露验证码、密码等敏感信息；遇到这类内容，热情但明确地请对方等用户本人回复。不编造用户的行程等个人信息。不写长篇大论。”,
        ]
        if !personaInstruction.isEmpty {
            parts.append(“用户为这个人设补充的专属要求：\n\(personaInstruction)”)
        }
        return parts.joined(separator: “\n\n”)
    }
}

struct AutoReplyService {
    let container: ModelContainer

    /// 每个发件人每天最多回 3 条；两次回复至少间隔 30 分钟
    private static let maxPerSenderPerDay = 3
    private static let minIntervalMinutes = 30
    /// 明确不自动回复的发件人前缀（机器人/系统地址，回了也白回，还容易循环）
    private static let skippedSenderPrefixes = [
        "noreply", "no-reply", "no_reply", "donotreply", "do-not-reply",
        "mailer-daemon", "postmaster", "notifications", "newsletter",
        "bounce", "alerts", "notification", "info@", "support@",
    ]
    /// 主题里出现这些词就不回（验证码/广告/系统通知）
    private static let skippedSubjectKeywords = [
        "验证码", "校验码", "动态码", "退订", "广告", "推广", "unsubscribe",
        "verification", "verify", "reset your password", "发票", "账单",
    ]

    /// 扫描最近 24 小时进收件箱、还没回过的邮件，逐封生成自动回复并投入发件队列。
    /// 在同步完成 / App 回到前台 / outbox 定时器时调用；开关没开直接返回。
    func processIfNeeded() async {
        guard AutoReplyStore.isEnabled else { return }
        let context = ModelContext(container)
        let cutoff = Date.now.addingTimeInterval(-24 * 3600)
        var descriptor = FetchDescriptor<MailMessage>(
            predicate: #Predicate { $0.date > cutoff },
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        descriptor.fetchLimit = 200

        let messages = (try? context.fetch(descriptor)) ?? []
        let responded = AutoReplyStore.respondedIDs()
        let accountEmails = fetchAccountEmails(context)

        for message in messages where shouldReply(message, accountEmails: accountEmails, responded: responded) {
            do {
                try await reply(to: message, context: context)
            } catch {
                // 单封失败不打断整体；messageID 不标记已回复，下次满足条件再试
                continue
            }
        }
    }

    private func fetchAccountEmails(_ context: ModelContext) -> [String] {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        return accounts.map { $0.email.lowercased() }
    }

    private func shouldReply(_ message: MailMessage, accountEmails: [String], responded: Set<String>) -> Bool {
        guard message.folder?.role == "inbox" else { return false }
        guard !message.messageID.isEmpty, !responded.contains(message.messageID) else { return false }

        let sender = MIMEParser.addresses(message.from).first?.lowercased() ?? ""
        guard !sender.isEmpty else { return false }
        // 不回自己账户发出的邮件（防自问自答循环）
        if accountEmails.contains(sender) { return false }
        // 不回系统机器人地址
        let local = sender.split(separator: "@").first.map(String.init)?.lowercased() ?? ""
        if Self.skippedSenderPrefixes.contains(where: { local.hasPrefix($0) || sender.hasPrefix($0) }) { return false }
        // 不回验证码/广告类主题
        let subject = message.subject.lowercased()
        if Self.skippedSubjectKeywords.contains(where: subject.contains) { return false }

        // 频率限制
        let times = AutoReplyStore.recentSendTimes(for: sender)
        if times.count >= Self.maxPerSenderPerDay { return false }
        if let last = times.max(), Date.now.timeIntervalSince(last) < Double(Self.minIntervalMinutes * 60) { return false }

        return true
    }

    private func reply(to message: MailMessage, context: ModelContext) async throws {
        guard let folder = message.folder, let account = folder.account else { return }
        guard let profile = FlyMailAI.primaryProfile() else { return }
        let key = KeychainStore.get(AIModelStore.keychainKey(for: profile.id)) ?? ""
        guard !key.isEmpty else { return }

        let body = message.bodyLoaded && !message.bodyText.isEmpty ? message.bodyText : message.snippet
        let userMessage = """
        收到一封新邮件，请以你的人设写一条自动回复。

        发件人：\(message.from)
        主题：\(message.subject)

        邮件内容：
        \(body)
        """

        let answer = try await FlyMailAI.chat(
            profile: profile,
            apiKey: key,
            messages: [
                AIChatMessage(role: "system", content: AutoReplyStore.personaSystemPrompt()),
                AIChatMessage(role: "user", content: userMessage),
            ],
            reasoning: nil,
            includeMemory: false
        )

        var draft = ComposeDraft(accountID: account.id)
        draft.to = message.from
        draft.subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
        draft.body = answer
        draft.inReplyTo = message.messageID

        let outbox = OutboxService(modelContainer: container)
        try outbox.enqueue(draft, accountID: account.id, sendAt: .now)
        AutoReplyStore.markResponded(message.messageID)
        AutoReplyStore.recordSend(to: MIMEParser.addresses(message.from).first?.lowercased() ?? message.from)
        await outbox.flushDue()
    }
}
