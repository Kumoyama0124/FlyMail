import Foundation
import SwiftData

enum AuthKind: String, Codable { case password, oauthGoogle, oauthMicrosoft }

@Model
final class Account {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var email: String
    var providerID: String
    var imapHost: String
    var imapPort: Int
    var imapTLS: Bool
    var smtpHost: String
    var smtpPort: Int
    /// true = 隐式 TLS(465)，false = STARTTLS(587)
    var smtpImplicitTLS: Bool
    var authKindRaw: String
    var signature: String
    var createdAt: Date
    var sortIndex: Int = 0
    var colorIndex: Int = 0
    /// 折叠时显示的文件夹类型
    var collapsedRoles: [String] = ["inbox", "sent"]
    /// 在侧边栏隐藏的文件夹路径
    var hiddenFolders: [String] = []
    /// 发件人名称（空则用显示名称）
    var senderName: String = ""
    /// 用户自定义分组，如“工作”“个人”
    var groupName: String = ""
    var isEnabled: Bool = true
    /// 可选的发件别名地址
    var aliases: [String] = []
    @Relationship(deleteRule: .cascade, inverse: \MailFolder.account) var folders: [MailFolder] = []

    var authKind: AuthKind { AuthKind(rawValue: authKindRaw) ?? .password }

    init(displayName: String, email: String, preset: ProviderPreset, authKind: AuthKind,
         imapHost: String? = nil, imapPort: Int? = nil, imapTLS: Bool = true,
         smtpHost: String? = nil, smtpPort: Int? = nil, smtpImplicitTLS: Bool? = nil) {
        id = UUID()
        self.displayName = displayName
        self.email = email
        providerID = preset.id
        self.imapHost = imapHost ?? preset.imapHost
        self.imapPort = imapPort ?? preset.imapPort
        self.imapTLS = imapTLS
        self.smtpHost = smtpHost ?? preset.smtpHost
        self.smtpPort = smtpPort ?? preset.smtpPort
        self.smtpImplicitTLS = smtpImplicitTLS ?? (preset.smtpPort == 465)
        authKindRaw = authKind.rawValue
        signature = "\n\n— 发自 FlyMail"
        createdAt = .now
    }
}

@Model
final class MailFolder {
    var path: String
    var name: String
    var isInbox: Bool
    var uidValidity: UInt32
    var lastUID: UInt32
    /// 特殊用途：inbox/trash/archive/junk/drafts/sent 或空
    var role: String = ""
    /// 用户自定义排序（-1 表示默认顺序）
    var sortIndex: Int = -1
    var account: Account?
    @Relationship(deleteRule: .cascade, inverse: \MailMessage.folder) var messages: [MailMessage] = []

    init(path: String, name: String, isInbox: Bool, account: Account) {
        self.path = path; self.name = name; self.isInbox = isInbox
        uidValidity = 0; lastUID = 0; self.account = account
    }
}

@Model
final class MailMessage {
    var uid: UInt32
    var subject: String
    var from: String
    var to: String
    var cc: String
    var date: Date
    var snippet: String
    var bodyText: String
    var bodyHTML: String?
    var messageID: String
    var isRead: Bool
    var isFlagged: Bool = false
    var spamScore: Int = 0
    var hasAttachment: Bool = false
    var size: Int = 0
    var spamReasons: [String] = []
    var bodyLoaded: Bool
    var attachmentNames: [String]
    var folder: MailFolder?

    init(uid: UInt32, subject: String, from: String, to: String, cc: String, date: Date,
         messageID: String, isRead: Bool, folder: MailFolder) {
        self.uid = uid; self.subject = subject; self.from = from; self.to = to; self.cc = cc
        self.date = date; self.messageID = messageID; self.isRead = isRead; self.folder = folder
        snippet = ""; bodyText = ""; bodyHTML = nil; bodyLoaded = false; attachmentNames = []
    }
}

/// 本地发件队列（含定时发送）
@Model
final class OutboxItem {
    var accountID: UUID
    var to: String
    var cc: String
    var bcc: String
    var subject: String
    var body: String
    var inReplyTo: String?
    var attachments: [AttachmentData]
    var sendAt: Date
    var attempts: Int
    var lastError: String?
    var messageID: String = ""
    var serverDraftUID: UInt32?
    var serverDraftFolder: String?

    init(accountID: UUID, draft: ComposeDraft, sendAt: Date) {
        self.accountID = accountID
        to = draft.to; cc = draft.cc; bcc = draft.bcc; subject = draft.subject
        body = draft.body; inReplyTo = draft.inReplyTo; attachments = draft.attachments
        self.sendAt = sendAt; attempts = 0
        messageID = draft.messageID
        serverDraftUID = draft.serverDraftUID; serverDraftFolder = draft.serverDraftFolder
    }
}

struct AttachmentData: Codable, Hashable, Identifiable {
    var id = UUID()
    var filename: String
    var mimeType: String
    var data: Data
}

struct ComposeDraft: Identifiable, Codable, Equatable {
    var id = UUID()
    var messageID = "<\(UUID().uuidString)@flymail>"
    var serverDraftUID: UInt32?
    var serverDraftFolder: String?
    var updatedAt = Date.now
    var accountID: UUID?
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""
    var inReplyTo: String?
    var attachments: [AttachmentData] = []
}

enum FolderRole {
    static func detect(path: String, name: String, flags: [String]) -> String {
        let f = Set(flags.map { $0.lowercased() })
        if path.uppercased() == "INBOX" { return "inbox" }
        if f.contains("\\trash") { return "trash" }
        if f.contains("\\junk") { return "junk" }
        if f.contains("\\drafts") { return "drafts" }
        if f.contains("\\sent") { return "sent" }
        if f.contains("\\archive") || f.contains("\\all") { return "archive" }
        let n = name.lowercased()
        if ["trash", "deleted", "deleted messages", "deleted items", "bin", "已删除", "已删除邮件", "废纸篓"].contains(n) { return "trash" }
        if ["junk", "spam", "junk e-mail", "junk email", "垃圾邮件", "垃圾箱"].contains(n) { return "junk" }
        if ["drafts", "draft", "草稿箱", "草稿"].contains(n) { return "drafts" }
        if ["sent", "sent messages", "sent items", "sent mail", "已发送", "已发送邮件"].contains(n) { return "sent" }
        if ["archive", "archives", "all mail", "归档", "存档"].contains(n) { return "archive" }
        return ""
    }
}

extension Account {
    func folder(role: String) -> MailFolder? { folders.first { $0.role == role } }
}
