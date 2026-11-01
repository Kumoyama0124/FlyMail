import Foundation

/// 本地草稿（App Support/Drafts/*.json），每几秒自动保存
enum LocalDraftStore {
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func save(_ d: ComposeDraft) {
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: dir.appendingPathComponent("\(d.id).json"), options: .atomic) }
    }
    static func delete(_ id: UUID) { try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json")) }
    static func all() -> [ComposeDraft] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { try? JSONDecoder().decode(ComposeDraft.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

/// 服务器草稿：APPEND 到“草稿箱”（\Draft），并删除上一版
enum DraftService {
    static func saveToServer(_ draft: ComposeDraft, cfg: AccountConfig, draftsPath: String) async throws -> UInt32? {
        let data = MIMEBuilder.build(from: cfg.email, fromName: cfg.displayName, to: MIMEParser.addresses(draft.to),
                                     cc: MIMEParser.addresses(draft.cc), subject: draft.subject, body: draft.body,
                                     inReplyTo: draft.inReplyTo, attachments: draft.attachments, messageID: draft.messageID)
        let imap = try await cfg.openIMAP()
        defer { Task { await imap.logout() } }
        var uid = try await imap.append(folder: draftsPath, message: data, flags: "\\Draft \\Seen")
        _ = try await imap.select(draftsPath)
        if uid == nil {   // 无 UIDPLUS：按 Message-ID 查找
            uid = try await imap.searchHeader("Message-ID", draft.messageID).max()
        }
        if let old = draft.serverDraftUID, draft.serverDraftFolder == draftsPath, old != uid {
            try? await imap.expunge(uids: [old])
        }
        return uid
    }

    static func deleteFromServer(uid: UInt32, folder: String, cfg: AccountConfig) async throws {
        try await MailActions.run(cfg, folder: folder, uids: [uid], op: .delete(trash: nil))
    }
}
