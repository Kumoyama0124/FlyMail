import Foundation

enum MailOp {
    case move(to: String)
    /// 有废纸篓且不在废纸篓中：移到废纸篓；否则彻底删除
    case delete(trash: String?)
    case flag(Bool)
    case seen(Bool)
    /// 标记垃圾邮件：设 $Junk 并移到垃圾邮件文件夹
    case markJunk(junk: String)
    /// 不是垃圾邮件：设 $NotJunk 并移回收件箱
    case notJunk(inbox: String)
    /// 清空当前文件夹（uids 被忽略）
    case emptyFolder
}

enum MailActions {
    static func run(_ cfg: AccountConfig, folder: String, uids: [UInt32], op: MailOp) async throws {
        let imap = try await cfg.openIMAP()
        defer { Task { await imap.logout() } }
        _ = try await imap.select(folder)
        if case .emptyFolder = op {} else {
            // 已不存在于服务器（别处删除/本地残留）：视为成功，让调用方删除本地记录
            let alive = try await imap.existingUIDs(uids)
            if alive.isEmpty { return }
            do { try await apply(imap, folder: folder, uids: uids.filter(alive.contains), op: op) }
            catch {
                if try await imap.existingUIDs(uids).isEmpty, !isFlagOp(op) { return }   // 实际已经生效
                throw error
            }
            return
        }
        try await apply(imap, folder: folder, uids: uids, op: op)
    }

    private static func isFlagOp(_ op: MailOp) -> Bool {
        switch op { case .flag, .seen: return true; default: return false }
    }

    private static func apply(_ imap: IMAPClient, folder: String, uids: [UInt32], op: MailOp) async throws {
        switch op {
        case .move(let to): try await imap.move(uids: uids, to: to)
        case .delete(let trash):
            if let trash, trash != folder { try await imap.move(uids: uids, to: trash) }
            else { try await imap.expunge(uids: uids) }
        case .flag(let on): try await imap.storeFlags(uids: uids, add: on, flags: "\\Flagged")
        case .seen(let on): try await imap.storeFlags(uids: uids, add: on, flags: "\\Seen")
        case .markJunk(let junk):
            try? await imap.storeFlags(uids: uids, add: false, flags: "$NotJunk")
            try? await imap.storeFlags(uids: uids, add: true, flags: "$Junk")
            try await imap.move(uids: uids, to: junk)
        case .notJunk(let inbox):
            try? await imap.storeFlags(uids: uids, add: false, flags: "$Junk")
            try? await imap.storeFlags(uids: uids, add: true, flags: "$NotJunk")
            try await imap.move(uids: uids, to: inbox)
        case .emptyFolder:
            let all = try await imap.uidSearch("ALL")
            for chunk in stride(from: 0, to: all.count, by: 200).map({ Array(all[$0..<min($0 + 200, all.count)]) }) {
                try await imap.expunge(uids: chunk)
            }
        }
    }
}
