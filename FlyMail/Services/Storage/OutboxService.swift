import Foundation
import SwiftData

/// 发件队列：立即发送与定时发送都经过这里
@ModelActor
actor OutboxService {
    func enqueue(_ draft: ComposeDraft, accountID: UUID, sendAt: Date) throws {
        modelContext.insert(OutboxItem(accountID: accountID, draft: draft, sendAt: sendAt))
        try modelContext.save()
    }

    /// 发送所有到期的邮件
    @discardableResult
    func flushDue() async -> Int {
        let now = Date.now
        let due = (try? modelContext.fetch(FetchDescriptor<OutboxItem>(predicate: #Predicate { $0.sendAt <= now }))) ?? []
        var sent = 0
        for item in due where item.attempts < 5 {
            do {
                try await send(item)
                modelContext.delete(item)
                sent += 1
            } catch {
                item.attempts += 1
                item.lastError = error.localizedDescription
            }
        }
        try? modelContext.save()
        return sent
    }

    private func send(_ item: OutboxItem) async throws {
        let aid = item.accountID
        guard let account = try modelContext.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.id == aid })).first else {
            throw MailNetError.protocolError("账户不存在")
        }
        let cfg = AccountConfig(account)
        let to = MIMEParser.addresses(item.to), cc = MIMEParser.addresses(item.cc), bcc = MIMEParser.addresses(item.bcc)
        let data = MIMEBuilder.build(from: cfg.email, fromName: cfg.displayName, to: to, cc: cc, subject: item.subject,
                                     body: item.body, inReplyTo: item.inReplyTo, attachments: item.attachments,
                                     messageID: item.messageID.isEmpty ? nil : item.messageID)
        let auth: SMTPAuth
        switch try await CredentialProvider.credential(accountID: cfg.id, kind: cfg.authKind) {
        case .password(let p): auth = .password(p)
        case .token(let t): auth = .xoauth2(t)
        }
        try await SMTPClient(host: cfg.smtpHost, port: cfg.smtpPort, implicitTLS: cfg.smtpImplicitTLS)
            .send(from: cfg.email, recipients: to + cc + bcc, data: data, user: cfg.email, auth: auth)
        // Gmail 会自动保存到已发送；其他服务商尝试 APPEND 到“已发送”
        let sentPath = account.providerID != "gmail" ? account.folder(role: "sent")?.path : nil
        let draftUID = item.serverDraftUID, draftFolder = item.serverDraftFolder
        if sentPath != nil || draftUID != nil, let imap = try? await cfg.openIMAP() {
            if let sentPath { try? await imap.append(folder: sentPath, message: data) }
            // 发送成功后删除服务器草稿
            if let draftUID, let draftFolder {
                if (try? await imap.select(draftFolder)) != nil { try? await imap.expunge(uids: [draftUID]) }
            }
            await imap.logout()
        }
    }
}
