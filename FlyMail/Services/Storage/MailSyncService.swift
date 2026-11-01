import Foundation
import Observation
import SwiftData

/// 账户连接配置快照（可跨 actor 传递）
struct AccountConfig: Sendable {
    let id: UUID, email: String, displayName: String
    let imapHost: String, imapPort: Int, imapTLS: Bool
    let smtpHost: String, smtpPort: Int, smtpImplicitTLS: Bool
    let authKind: AuthKind

    init(_ a: Account) {
        id = a.id; email = a.email; displayName = a.senderName.isEmpty ? a.displayName : a.senderName
        imapHost = a.imapHost; imapPort = a.imapPort; imapTLS = a.imapTLS
        smtpHost = a.smtpHost; smtpPort = a.smtpPort; smtpImplicitTLS = a.smtpImplicitTLS
        authKind = a.authKind
    }

    func openIMAP() async throws -> IMAPClient {
        let c = IMAPClient(host: imapHost, port: imapPort, tls: imapTLS)
        try await c.connect()
        switch try await CredentialProvider.credential(accountID: id, kind: authKind) {
        case .password(let pw): try await c.login(user: email, password: pw)
        case .token(let t): try await c.authenticateXOAuth2(user: email, accessToken: t)
        }
        return c
    }
}

/// 同步：IMAP → SwiftData 本地缓存
@ModelActor
actor MailSyncService {

    /// 同步所有账户，返回新邮件数
    @discardableResult
    func syncAll(notify: Bool = false) async -> Int {
        let accounts = (try? modelContext.fetch(FetchDescriptor<Account>())) ?? []
        var total = 0
        for a in accounts where a.isEnabled {
            do { total += try await sync(accountID: a.persistentModelID, notify: notify) }
            catch {
                print("sync \(a.email) failed: \(error)")
                AccountStatus.set(a.id, .failed(error.localizedDescription))
            }
        }
        Task { await self.prefetchBodies(onWiFi: NetworkMonitor.shared.onWiFi, maxCount: 100) }
        return total
    }

    func sync(accountID: PersistentIdentifier, notify: Bool = false) async throws -> Int {
        guard let account = modelContext.model(for: accountID) as? Account else { return 0 }
        let cfg = AccountConfig(account)
        AccountStatus.set(cfg.id, .syncing)
        let imap = try await cfg.openIMAP()
        defer { Task { await imap.logout() } }

        // 文件夹
        let remote = try await imap.list()
        for f in remote {
            let role = FolderRole.detect(path: f.path, name: f.name, flags: f.flags)
            if let existing = account.folders.first(where: { $0.path == f.path }) {
                existing.role = role
            } else {
                let folder = MailFolder(path: f.path, name: f.path.uppercased() == "INBOX" ? "收件箱" : f.name,
                                        isInbox: f.path.uppercased() == "INBOX", account: account)
                folder.role = role
                modelContext.insert(folder)
            }
        }
        // 合并同一账户下路径相同的重复文件夹对象（侧边栏按角色去重后只显示一个，
        // 但统一收件箱按角色查询会把重复对象里的邮件都算进来，造成“单账户收件箱已空、
        // 统一收件箱仍有残留”的假象）。先把重复对象里的邮件移到第一个对象，再删重复对象。
        var folderGroups: [String: [MailFolder]] = [:]
        for f in account.folders { folderGroups[f.path, default: []].append(f) }
        for (_, list) in folderGroups where list.count > 1 {
            let keep = list[0]
            for dup in list.dropFirst() {
                for m in dup.messages { m.folder = keep }
                modelContext.delete(dup)
            }
        }
        try modelContext.save()

        var newCount = 0
        // v1 仅自动同步收件箱，其他文件夹在打开时按需同步
        for folder in account.folders where folder.isInbox {
            newCount += try await syncFolder(folder, imap: imap, notify: notify, accountName: cfg.displayName)
        }
        AccountStatus.set(cfg.id, .ok)
        return newCount
    }

    /// 同步所有账户里某一类特殊文件夹（统一归档/垃圾邮件/废纸箱视图）
    func syncRole(_ role: String) async {
        let folders = ((try? modelContext.fetch(FetchDescriptor<MailFolder>())) ?? []).filter { $0.role == role }
        for f in folders { try? await syncFolder(id: f.persistentModelID) }
    }

    func syncFolder(id: PersistentIdentifier) async throws {
        guard let folder = modelContext.model(for: id) as? MailFolder, let a = folder.account else { return }
        let imap = try await AccountConfig(a).openIMAP()
        defer { Task { await imap.logout() } }
        _ = try await syncFolder(folder, imap: imap, notify: false, accountName: a.displayName)
    }

    /// IMAP SEARCH 用的日期（RFC 3501：1-Jan-2026，月份必须是英文）
    static func imapDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "d-MMM-yyyy"
        return f.string(from: d)
    }

    static let maxPerSync = 3000

    private func syncFolder(_ folder: MailFolder, imap: IMAPClient, notify: Bool, accountName: String) async throws -> Int {
        let info = try await imap.select(folder.path, readOnly: true)
        // UIDVALIDITY 变化：服务器 UID 全部作废，清空本地缓存
        if info.uidValidity != folder.uidValidity {
            folder.messages.forEach { modelContext.delete($0) }
            folder.uidValidity = info.uidValidity
            folder.lastUID = 0
        }
        // 1) 对账：服务器已不存在的邮件从本地删除（修复“服务器已空、本地残留”）
        let serverAll = info.exists == 0 ? Set<UInt32>() : try await imap.allUIDs()
        var local: [UInt32: MailMessage] = [:]
        for m in folder.messages {
            if !serverAll.contains(m.uid) || local[m.uid] != nil { modelContext.delete(m) } else { local[m.uid] = m }
        }
        // 1b) 核对旧邮件的已读/星标：以前只给新邮件设 Seen，旧邮件在苹果邮件、
        // 网页版等别处读过之后，本地永远还是未读，侧边栏就一直挂着幻影未读数。
        // 用轻量 UID FLAGS（不拉头部、不拉正文）把本地状态跟服务器对齐。
        if !local.isEmpty {
            for chunk in stride(from: 0, to: local.count, by: 200).map({ Array(Array(local.keys)[$0..<min($0 + 200, local.count)]) }) {
                if let flags = try? await imap.fetchFlags(uids: chunk) {
                    for (uid, fl) in flags {
                        guard let m = local[uid] else { continue }
                        let seen = fl.contains("\\Seen"), flagged = fl.contains("\\Flagged")
                        if m.isRead != seen { m.isRead = seen }
                        if m.isFlagged != flagged { m.isFlagged = flagged }
                    }
                }
            }
            try modelContext.save()
        }
        // 2) 同步范围内缺失的邮件（新邮件 + 扩大范围后的回填）
        let days = Prefs.rangeDays
        var window: [UInt32]
        if serverAll.isEmpty { window = [] }
        else if days > 0 {
            let since = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .now
            window = try await imap.uidSearch("SINCE \(Self.imapDate(since))")
        } else { window = serverAll.sorted() }
        let isInitial = folder.lastUID == 0
        var uids = window.filter { local[$0] == nil }.sorted()
        if uids.count > Self.maxPerSync { uids = Array(uids.suffix(Self.maxPerSync)) }
        uids.reverse()   // 新邮件优先
        var added = 0
        var spam: [MailMessage] = []
        for chunk in stride(from: 0, to: uids.count, by: 50).map({ Array(uids[$0..<min($0 + 50, uids.count)]) }) {
            for h in try await imap.fetchHeaders(uids: chunk) {
                let hd = MIMEParser.parseHeaders(h.header)
                let m = MailMessage(uid: h.uid, subject: hd["subject"] ?? "(无主题)", from: hd["from"] ?? "",
                                    to: hd["to"] ?? "", cc: hd["cc"] ?? "", date: MIMEParser.parseDate(hd["date"]),
                                    messageID: hd["message-id"] ?? "", isRead: h.flags.contains("\\Seen"), folder: folder)
                m.isFlagged = h.flags.contains("\\Flagged")
                m.size = h.size
                (m.spamScore, m.spamReasons) = SpamFilter.evaluate(headers: hd, subject: m.subject, from: m.from)
                m.hasAttachment = (hd["content-type"] ?? "").lowercased().contains("multipart/mixed")
                modelContext.insert(m)
                if folder.isInbox, SpamFilter.autoMove, m.spamScore >= SpamFilter.threshold { spam.append(m) }
                let isNew = h.uid > folder.lastUID
                if isNew { added += 1 }
                if notify && !isInitial && isNew && !m.isRead && m.spamScore < SpamFilter.threshold {
                    NotificationService.notifyNewMail(account: accountName, from: m.from, subject: m.subject)
                }
            }
            try modelContext.save()
        }
        folder.lastUID = max(folder.lastUID, serverAll.max() ?? 0)
        // 自动移入垃圾邮件
        if !spam.isEmpty, let junk = folder.account?.folder(role: "junk") {
            _ = try await imap.select(folder.path)
            if (try? await imap.move(uids: spam.map(\.uid), to: junk.path)) != nil {
                spam.forEach { modelContext.delete($0) }
                added = max(0, added - spam.count)
            }
        }
        try modelContext.save()
        return added
    }

    private func apply(_ raw: Data, to m: MailMessage, folder: MailFolder, account: Account) {
        let parsed = MIMEParser.parse(raw)
        m.bodyText = parsed.text
        m.bodyHTML = parsed.html
        m.snippet = String(parsed.text.prefix(140)).replacingOccurrences(of: "\n", with: " ")
        m.attachmentNames = AttachmentStore.save(parsed.attachments, accountID: account.id, folder: folder.path,
                                                 uidValidity: folder.uidValidity, uid: m.uid)
        (m.spamScore, m.spamReasons) = SpamFilter.evaluate(headers: parsed.headers, subject: m.subject, from: m.from,
                                                           text: parsed.text, html: parsed.html)
        m.hasAttachment = !m.attachmentNames.isEmpty
        if m.size == 0 { m.size = raw.count }
        m.bodyLoaded = true
    }

    func loadBody(messageID: PersistentIdentifier) async throws {
        guard let m = modelContext.model(for: messageID) as? MailMessage,
              let folder = m.folder, let a = folder.account else { return }
        if m.bodyLoaded {   // 已缓存：直接显示，本地先标已读，服务器补发不阻塞详情页
            if !m.isRead {
                m.isRead = true; try modelContext.save()
                Task { try? await self.setRead(messageID: messageID, true) }
            }
            return
        }
        let imap = try await AccountConfig(a).openIMAP()
        defer { Task { await imap.logout() } }
        _ = try await imap.select(folder.path)
        // 先走分段取文本：只拉 text/html、text/plain（+ 小的内嵌图），不拉附件，
        // 带大附件的邮件也不用等整封下载。任何一步失败都回落到整封下载。
        if await fetchTextOnly(imap: imap, message: m, folder: folder, account: a) {
            if !m.isRead { try await imap.setSeen(uid: m.uid, true); m.isRead = true }
            try modelContext.save()
            return
        }
        let raw = try await imap.fetchBody(uid: m.uid)
        if raw.isEmpty, try await imap.existingUIDs([m.uid]).isEmpty {   // 服务器上已被删除
            modelContext.delete(m); try modelContext.save(); return
        }
        apply(raw, to: m, folder: folder, account: a)
        if !m.isRead { try await imap.setSeen(uid: m.uid, true); m.isRead = true }
        try modelContext.save()
    }

    /// 分段取正文（不标已读）：BODYSTRUCTURE 找文本分段，只拉那几段。
    /// 返回 true 表示正文已可用；false 表示解析/拉取失败，调用方回落整封下载。
    private func fetchTextOnly(imap: IMAPClient, message m: MailMessage, folder: MailFolder, account: Account) async -> Bool {
        guard let structure = try? await imap.fetchStructure(uid: m.uid), !structure.isEmpty,
              let parts = BodyStructure.parse(structure) else { return false }
        let htmlPart = parts.first { $0.mime == "text/html" && !$0.isAttachment }
        let plainPart = parts.first { $0.mime == "text/plain" && !$0.isAttachment }
        guard htmlPart != nil || plainPart != nil else { return false }
        var html: String?, text = ""
        if let hp = htmlPart {
            guard let mimeData = try? await imap.fetchSectionMIME(uid: m.uid, section: hp.section),
                  let raw = try? await imap.fetchSection(uid: m.uid, section: hp.section), !raw.isEmpty else { return false }
            let hdr = MIMEParser.parseHeaderBlock(String(decoding: mimeData, as: UTF8.self))
            let decoded = MIMEParser.decodeTransfer(raw, encoding: hdr["content-transfer-encoding"]?.lowercased() ?? "")
            var h = MIMEParser.decodeCharset(decoded, MIMEParser.parameters(hdr["content-type"] ?? "")["charset"])
            // 小的内嵌图顺带拉上（总共不超过 1MB），否则 html 里的 cid: 图全是破图
            var budget = 1 << 20
            for img in parts.filter({ $0.isInlineImage && $0.size <= 512 * 1024 }) where budget > 0 {
                guard let cid = img.contentID,
                      let imgMime = try? await imap.fetchSectionMIME(uid: m.uid, section: img.section),
                      let imgRaw = try? await imap.fetchSection(uid: m.uid, section: img.section), !imgRaw.isEmpty else { continue }
                let imgHdr = MIMEParser.parseHeaderBlock(String(decoding: imgMime, as: UTF8.self))
                let imgData = MIMEParser.decodeTransfer(imgRaw, encoding: imgHdr["content-transfer-encoding"]?.lowercased() ?? "")
                h = h.replacingOccurrences(of: "cid:\(cid)", with: "data:\(img.mime);base64,\(imgData.base64EncodedString())")
                budget -= imgData.count
            }
            html = h
        }
        if let pp = plainPart {
            guard let mimeData = try? await imap.fetchSectionMIME(uid: m.uid, section: pp.section),
                  let raw = try? await imap.fetchSection(uid: m.uid, section: pp.section), !raw.isEmpty else { return false }
            let hdr = MIMEParser.parseHeaderBlock(String(decoding: mimeData, as: UTF8.self))
            let decoded = MIMEParser.decodeTransfer(raw, encoding: hdr["content-transfer-encoding"]?.lowercased() ?? "")
            text = MIMEParser.decodeCharset(decoded, MIMEParser.parameters(hdr["content-type"] ?? "")["charset"])
        }
        guard html != nil || !text.isEmpty else { return false }
        m.bodyHTML = html
        m.bodyText = !text.isEmpty ? text : (html.map { MIMEParser.stripHTML($0) } ?? "")
        m.snippet = String(m.bodyText.prefix(140)).replacingOccurrences(of: "\n", with: " ")
        let names = parts.filter { $0.isAttachment }.compactMap { $0.filename }
        m.attachmentNames = names
        m.hasAttachment = !names.isEmpty
        m.bodyLoaded = true
        return true
    }

    /// 预取单封正文（不标已读）：供详情页预取上一封/下一封用，点上一封/下一封时直接读缓存
    func prefetchBody(messageID: PersistentIdentifier) async {
        guard let m = modelContext.model(for: messageID) as? MailMessage, !m.bodyLoaded,
              let folder = m.folder, let a = folder.account,
              let imap = try? await AccountConfig(a).openIMAP() else { return }
        defer { Task { await imap.logout() } }
        guard (try? await imap.select(folder.path, readOnly: true)) != nil else { return }
        if await fetchTextOnly(imap: imap, message: m, folder: folder, account: a) { try? modelContext.save(); return }
        guard let raw = try? await imap.fetchBody(uid: m.uid), !raw.isEmpty else { return }
        apply(raw, to: m, folder: folder, account: a)
        try? modelContext.save()
    }

    /// 后台预取正文：新邮件优先，最多 4 条并发连接；只预取收件箱，只拉文本部分，
    /// 不再按整封大小（含附件）卡住——带大附件的邮件正文也能预取到，附件点开再下。不标记已读
    func prefetchBodies(onWiFi: Bool, maxCount: Int = 60) async {
        let limit = Prefs.prefetchLimit(onWiFi: onWiFi)
        guard limit > 0 else { return }
        let all = (try? modelContext.fetch(FetchDescriptor<MailMessage>(predicate: #Predicate { !$0.bodyLoaded },
                                                                         sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        let targets = all.filter { m in
            (m.folder?.role ?? "") == "inbox"
        }.prefix(maxCount)
        // 按账户 + 文件夹分组，便于复用 SELECT
        var groups: [String: [MailMessage]] = [:]
        for m in targets { groups[(m.folder?.account?.id.uuidString ?? "") + "|" + (m.folder?.path ?? ""), default: []].append(m) }
        let jobs = Array(groups.values)
        await withTaskGroup(of: Void.self) { g in
            var next = 0
            func add() {
                guard next < jobs.count else { return }
                let ids = jobs[next].map(\.persistentModelID); next += 1
                g.addTask { await self.prefetch(ids) }
            }
            add(); add(); add(); add()
            while await g.next() != nil { add() }
        }
    }

    private func prefetch(_ ids: [PersistentIdentifier]) async {
        guard let first = ids.first.flatMap({ modelContext.model(for: $0) as? MailMessage }),
              let folder = first.folder, let a = folder.account,
              let imap = try? await AccountConfig(a).openIMAP() else { return }
        defer { Task { await imap.logout() } }
        guard (try? await imap.select(folder.path, readOnly: true)) != nil else { return }
        for id in ids {
            if Task.isCancelled { return }
            guard let m = modelContext.model(for: id) as? MailMessage, !m.bodyLoaded else { continue }
            if await fetchTextOnly(imap: imap, message: m, folder: folder, account: a) { try? modelContext.save(); continue }
            guard let raw = try? await imap.fetchBody(uid: m.uid), !raw.isEmpty else { continue }
            apply(raw, to: m, folder: folder, account: a)
            try? modelContext.save()
        }
    }

    /// 附件缓存丢失时重新下载整封邮件并写入缓存
    func ensureAttachments(messageID: PersistentIdentifier) async throws {
        guard let m = modelContext.model(for: messageID) as? MailMessage, let folder = m.folder, let a = folder.account else { return }
        if m.attachmentNames.allSatisfy({ AttachmentStore.url(accountID: a.id, folder: folder.path, uidValidity: folder.uidValidity, uid: m.uid, name: $0).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }) { return }
        let imap = try await AccountConfig(a).openIMAP()
        defer { Task { await imap.logout() } }
        _ = try await imap.select(folder.path, readOnly: true)
        let parsed = MIMEParser.parse(try await imap.fetchBody(uid: m.uid))
        m.attachmentNames = AttachmentStore.save(parsed.attachments, accountID: a.id, folder: folder.path,
                                                 uidValidity: folder.uidValidity, uid: m.uid)
        try modelContext.save()
    }

    func setRead(messageID: PersistentIdentifier, _ read: Bool) async throws {
        guard let m = modelContext.model(for: messageID) as? MailMessage, let f = m.folder, let a = f.account else { return }
        m.isRead = read
        try modelContext.save()
        let imap = try await AccountConfig(a).openIMAP()
        defer { Task { await imap.logout() } }
        _ = try await imap.select(f.path)
        try await imap.setSeen(uid: m.uid, read)
    }

    /// 全局服务器搜索：所有账户并行，在收件箱/已发送/归档/自定义文件夹中 UID SEARCH，
    /// 本地没有的结果拉取头部写入缓存，返回命中的本地记录 ID
    func globalServerSearch(_ query: String, scope: String, accountID: UUID?) async -> [PersistentIdentifier] {
        let q = query.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "")
        guard !q.isEmpty else { return [] }
        let key: String = ["from": "FROM", "subject": "SUBJECT", "body": "BODY"][scope] ?? "TEXT"
        let accounts = ((try? modelContext.fetch(FetchDescriptor<Account>())) ?? []).filter { $0.isEnabled && (accountID == nil || $0.id == accountID) }
        let jobs: [(AccountConfig, [(PersistentIdentifier, String)])] = accounts.map { a in
            (AccountConfig(a), a.folders.filter { !["junk", "trash", "drafts"].contains($0.role) }.map { ($0.persistentModelID, $0.path) })
        }
        var hits: [(PersistentIdentifier, [UInt32])] = []
        await withTaskGroup(of: [(PersistentIdentifier, [UInt32])].self) { g in
            for (cfg, folders) in jobs {
                g.addTask {
                    guard let imap = try? await cfg.openIMAP() else { return [] }
                    var out: [(PersistentIdentifier, [UInt32])] = []
                    for (fid, path) in folders.prefix(12) {
                        guard (try? await imap.select(path, readOnly: true)) != nil else { continue }
                        let u = (try? await imap.uidSearch("CHARSET UTF-8 \(key) \"\(q)\"")) ?? []
                        if !u.isEmpty { out.append((fid, Array(u.suffix(200)))) }
                    }
                    await imap.logout()
                    return out
                }
            }
            for await r in g { hits += r }
        }
        var ids: [PersistentIdentifier] = []
        for (fid, uids) in hits {
            guard let folder = modelContext.model(for: fid) as? MailFolder, let a = folder.account else { continue }
            let have = Dictionary(folder.messages.map { ($0.uid, $0) }, uniquingKeysWith: { l, _ in l })
            let missing = uids.filter { have[$0] == nil }
            ids += uids.compactMap { have[$0]?.persistentModelID }
            guard !missing.isEmpty, let imap = try? await AccountConfig(a).openIMAP() else { continue }
            if (try? await imap.select(folder.path, readOnly: true)) != nil,
               let headers = try? await imap.fetchHeaders(uids: Array(missing.suffix(100))) {
                for h in headers {
                    let hd = MIMEParser.parseHeaders(h.header)
                    let m = MailMessage(uid: h.uid, subject: hd["subject"] ?? "(无主题)", from: hd["from"] ?? "",
                                        to: hd["to"] ?? "", cc: hd["cc"] ?? "", date: MIMEParser.parseDate(hd["date"]),
                                        messageID: hd["message-id"] ?? "", isRead: h.flags.contains("\\Seen"), folder: folder)
                    m.isFlagged = h.flags.contains("\\Flagged"); m.size = h.size
                    m.hasAttachment = (hd["content-type"] ?? "").lowercased().contains("multipart/mixed")
                    (m.spamScore, m.spamReasons) = SpamFilter.evaluate(headers: hd, subject: m.subject, from: m.from)
                    modelContext.insert(m)
                    ids.append(m.persistentModelID)
                }
            }
            await imap.logout()
        }
        try? modelContext.save()
        return ids
    }

    /// 服务器端搜索（IMAP SEARCH TEXT），结果合入本地缓存
    func remoteSearch(folderID: PersistentIdentifier, query: String) async throws -> [UInt32] {
        guard let f = modelContext.model(for: folderID) as? MailFolder, let a = f.account else { return [] }
        let imap = try await AccountConfig(a).openIMAP()
        defer { Task { await imap.logout() } }
        _ = try await imap.select(f.path, readOnly: true)
        let q = query.replacingOccurrences(of: "\"", with: "")
        return try await imap.uidSearch("CHARSET UTF-8 TEXT \"\(q)\"")
    }
}

/// 账户连接状态（内存，供账户管理页显示）
@MainActor @Observable
final class AccountStatus {
    enum State: Equatable { case unknown, syncing, ok, failed(String) }
    static let shared = AccountStatus()
    var states: [UUID: State] = [:]
    nonisolated static func set(_ id: UUID, _ s: State) {
        Task { @MainActor in shared.states[id] = s }
    }
}
