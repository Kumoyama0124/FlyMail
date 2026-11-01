import Foundation
import SwiftData
import UniformTypeIdentifiers

/// 本地备份与恢复：打包成一个 zip，App 自己就能导出来、自己就能导回去，
/// 不走 iCloud、不走服务器，换机时把 zip 传到新手机上导入就行。
///
/// 备份里有什么：
/// - 账户（名称、邮箱、服务商、IMAP/SMTP 服务器和端口、签名、颜色、分组、文件夹设置）
/// - 外观 / 同步 / 滑动 / 侧边栏设置、VIP、垃圾名单、本地草稿
/// 备份里没有：
/// - 邮件正文和附件：本来就在服务器上，恢复后登录账户、同步一次就回来了，不用占备份体积
/// - 密码、授权码、OAuth 令牌：故意不放进 zip，否则 zip 一旦外流就是明文密码；
///   恢复后每个账户重新输一次密码或重新登录一次，就能正常用
struct BackupFolder: Codable {
    var path: String, name: String, isInbox: Bool, role: String, sortIndex: Int
}

struct BackupAccount: Codable {
    var id: UUID, displayName: String, email: String, providerID: String
    var imapHost: String, imapPort: Int, imapTLS: Bool
    var smtpHost: String, smtpPort: Int, smtpImplicitTLS: Bool
    var authKindRaw: String, signature: String, sortIndex: Int, colorIndex: Int
    var collapsedRoles: [String], hiddenFolders: [String], senderName: String
    var groupName: String, isEnabled: Bool, aliases: [String]
    var folders: [BackupFolder]
}

struct BackupPrefs: Codable {
    var showAvatars: Bool, remoteAvatars: Bool, defaultAccount: String, badgeSource: String
    var grouping: Bool, vipList: String, density: Int, previewLines: Int, accent: Int
    var leading1: String, leading2: String, trailing1: String, trailing2: String
    var syncRangeDays: Int, syncInterval: Int, autoBody: String, autoAttach: String
    var smartOrder: String, smartHidden: String
    var sidebarExpanded: String, sidebarCollapsed: String, sidebarMoreExpanded: String
    var spamThreshold: Int, spamAutoMove: Bool, spamBlock: [String], spamAllow: [String]
}

struct BackupData: Codable {
    var version: Int, exportedAt: Date, app: String
    var accounts: [BackupAccount], prefs: BackupPrefs
}

struct ParsedBackup {
    var data: BackupData
    var drafts: [(name: String, data: Data)]
    var summary: String {
        let emails = data.accounts.map(\.email).joined(separator: "、")
        return "共 \(data.accounts.count) 个账户\(emails.isEmpty ? "" : "：\(emails)")，本地草稿 \(drafts.count) 份"
    }
}

enum LocalBackup {
    // MARK: - 导出

    static func exportURL(context: ModelContext) throws -> URL {
        let d = UserDefaults.standard
        let prefs = BackupPrefs(
            showAvatars: d.object(forKey: Prefs.showAvatars) as? Bool ?? true,
            remoteAvatars: d.object(forKey: Prefs.remoteAvatars) as? Bool ?? true,
            defaultAccount: d.string(forKey: Prefs.defaultAccount) ?? "",
            badgeSource: d.string(forKey: Prefs.badgeSource) ?? "inbox",
            grouping: d.bool(forKey: Prefs.grouping),
            vipList: d.string(forKey: Prefs.vipList) ?? "",
            density: d.object(forKey: Prefs.density) as? Int ?? 1,
            previewLines: d.object(forKey: Prefs.previewLines) as? Int ?? 2,
            accent: d.object(forKey: Prefs.accent) as? Int ?? 0,
            leading1: d.string(forKey: Prefs.leading1) ?? "read",
            leading2: d.string(forKey: Prefs.leading2) ?? "flag",
            trailing1: d.string(forKey: Prefs.trailing1) ?? "delete",
            trailing2: d.string(forKey: Prefs.trailing2) ?? "archive",
            syncRangeDays: d.object(forKey: Prefs.syncRangeDays) as? Int ?? 30,
            syncInterval: d.object(forKey: Prefs.syncInterval) as? Int ?? 0,
            autoBody: d.string(forKey: Prefs.autoBody) ?? "all",
            autoAttach: d.string(forKey: Prefs.autoAttach) ?? "5",
            smartOrder: d.string(forKey: Prefs.smartOrder) ?? Prefs.defaultSmartOrder,
            smartHidden: d.string(forKey: Prefs.smartHidden) ?? "",
            sidebarExpanded: d.string(forKey: "sidebar.expanded") ?? "",
            sidebarCollapsed: d.string(forKey: "sidebar.collapsed") ?? "",
            sidebarMoreExpanded: d.string(forKey: "sidebar.moreExpanded") ?? "",
            spamThreshold: d.object(forKey: SpamFilter.thresholdKey) as? Int ?? 50,
            spamAutoMove: d.bool(forKey: SpamFilter.autoMoveKey),
            spamBlock: d.stringArray(forKey: SpamFilter.blockKey) ?? [],
            spamAllow: d.stringArray(forKey: SpamFilter.allowKey) ?? []
        )
        let accounts = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let backupAccounts = accounts.map { a in
            BackupAccount(id: a.id, displayName: a.displayName, email: a.email, providerID: a.providerID,
                          imapHost: a.imapHost, imapPort: a.imapPort, imapTLS: a.imapTLS,
                          smtpHost: a.smtpHost, smtpPort: a.smtpPort, smtpImplicitTLS: a.smtpImplicitTLS,
                          authKindRaw: a.authKindRaw, signature: a.signature, sortIndex: a.sortIndex,
                          colorIndex: a.colorIndex, collapsedRoles: a.collapsedRoles, hiddenFolders: a.hiddenFolders,
                          senderName: a.senderName, groupName: a.groupName, isEnabled: a.isEnabled, aliases: a.aliases,
                          folders: a.folders.map { BackupFolder(path: $0.path, name: $0.name, isInbox: $0.isInbox, role: $0.role, sortIndex: $0.sortIndex) })
        }
        let data = BackupData(version: 1, exportedAt: .now, app: "FlyMail", accounts: backupAccounts, prefs: prefs)
        let json = try JSONEncoder().encode(data)
        var entries: [(String, Data)] = [("backup.json", json)]
        // 本地草稿文件原样打包
        let draftsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Drafts", isDirectory: true)
        for url in (try? FileManager.default.contentsOfDirectory(at: draftsDir, includingPropertiesForKeys: nil)) ?? [] {
            if let d = try? Data(contentsOf: url) { entries.append(("drafts/" + url.lastPathComponent, d)) }
        }
        let zip = try ZipStore.write(entries)
        let name = "FlyMail-backup-" + ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-") + ".zip"
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try zip.write(to: out)
        return out
    }

    // MARK: - 导入（先解析校验，确认后再覆盖）

    static func parse(url: URL) throws -> ParsedBackup {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let zip = try Data(contentsOf: url)
        let entries = try ZipStore.read(zip)
        // 兼容被“文件”App / Mac 重新压缩过的 zip：backup.json 可能在子文件夹里，还会带 __MACOSX 垃圾条目
        let usable = entries.filter { !$0.key.hasPrefix("__MACOSX/") && !$0.key.hasSuffix("/") }
        let jsonKey = usable.keys.filter { $0 == "backup.json" || $0.hasSuffix("/backup.json") }.min { $0.count < $1.count }
        guard let jsonKey, let json = usable[jsonKey] else { throw BackupError.noBackupJson }
        let data = try JSONDecoder().decode(BackupData.self, from: json)
        guard data.version == 1 else { throw BackupError.unsupportedVersion }
        let drafts = usable
            .filter { $0.key.hasPrefix("drafts/") || $0.key.contains("/drafts/") }
            .map { (name: ($0.key as NSString).lastPathComponent, data: $0.value) }
        return ParsedBackup(data: data, drafts: drafts)
    }

    static func restore(_ parsed: ParsedBackup, context: ModelContext) throws {
        let data = parsed.data
        // 校验通过后才动现有数据：先删旧账户（级联删文件夹和本地邮件缓存），再按备份重建
        for a in (try? context.fetch(FetchDescriptor<Account>())) ?? [] {
            KeychainStore.deleteAll(accountID: a.id)
            context.delete(a)
        }
        try context.save()
        for ba in data.accounts {
            let preset = ProviderPreset.preset(ba.providerID)
            let a = Account(displayName: ba.displayName, email: ba.email, preset: preset,
                            authKind: AuthKind(rawValue: ba.authKindRaw) ?? .password,
                            imapHost: ba.imapHost, imapPort: ba.imapPort, imapTLS: ba.imapTLS,
                            smtpHost: ba.smtpHost, smtpPort: ba.smtpPort, smtpImplicitTLS: ba.smtpImplicitTLS)
            a.id = ba.id; a.signature = ba.signature; a.sortIndex = ba.sortIndex; a.colorIndex = ba.colorIndex
            a.collapsedRoles = ba.collapsedRoles; a.hiddenFolders = ba.hiddenFolders; a.senderName = ba.senderName
            a.groupName = ba.groupName; a.isEnabled = ba.isEnabled; a.aliases = ba.aliases
            context.insert(a)
            for bf in ba.folders {
                let f = MailFolder(path: bf.path, name: bf.name, isInbox: bf.isInbox, account: a)
                f.role = bf.role; f.sortIndex = bf.sortIndex
                context.insert(f)
            }
        }
        try context.save()
        // 设置、VIP、垃圾名单
        let d = UserDefaults.standard, p = data.prefs
        d.set(p.showAvatars, forKey: Prefs.showAvatars); d.set(p.remoteAvatars, forKey: Prefs.remoteAvatars)
        d.set(p.defaultAccount, forKey: Prefs.defaultAccount); d.set(p.badgeSource, forKey: Prefs.badgeSource)
        d.set(p.grouping, forKey: Prefs.grouping); d.set(p.vipList, forKey: Prefs.vipList)
        d.set(p.density, forKey: Prefs.density); d.set(p.previewLines, forKey: Prefs.previewLines)
        d.set(p.accent, forKey: Prefs.accent)
        d.set(p.leading1, forKey: Prefs.leading1); d.set(p.leading2, forKey: Prefs.leading2)
        d.set(p.trailing1, forKey: Prefs.trailing1); d.set(p.trailing2, forKey: Prefs.trailing2)
        d.set(p.syncRangeDays, forKey: Prefs.syncRangeDays); d.set(p.syncInterval, forKey: Prefs.syncInterval)
        d.set(p.autoBody, forKey: Prefs.autoBody); d.set(p.autoAttach, forKey: Prefs.autoAttach)
        d.set(p.smartOrder, forKey: Prefs.smartOrder); d.set(p.smartHidden, forKey: Prefs.smartHidden)
        d.set(p.sidebarExpanded, forKey: "sidebar.expanded"); d.set(p.sidebarCollapsed, forKey: "sidebar.collapsed")
        d.set(p.sidebarMoreExpanded, forKey: "sidebar.moreExpanded")
        d.set(p.spamThreshold, forKey: SpamFilter.thresholdKey); d.set(p.spamAutoMove, forKey: SpamFilter.autoMoveKey)
        d.set(p.spamBlock, forKey: SpamFilter.blockKey); d.set(p.spamAllow, forKey: SpamFilter.allowKey)
        // 本地草稿：先清空旧的，再写回备份里的
        let draftsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: draftsDir, withIntermediateDirectories: true)
        for url in (try? FileManager.default.contentsOfDirectory(at: draftsDir, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: url)
        }
        for draft in parsed.drafts {
            try? draft.data.write(to: draftsDir.appendingPathComponent(draft.name))
        }
    }

    enum BackupError: LocalizedError {
        case noBackupJson, unsupportedVersion, unsupportedCompression
        var errorDescription: String? {
            switch self {
            case .unsupportedCompression: return "这个 zip 的压缩方式读不了，请用 App 导出的原始备份文件"
            case .noBackupJson: return "这个 zip 里没有 backup.json，不是 FlyMail 导出的备份"
            case .unsupportedVersion: return "备份版本太新或太旧，当前 App 读不了"
            }
        }
    }
}

/// 最小 zip 实现（只写/只读不压缩的 stored 条目，不引入第三方库）：
/// 写出来的 zip 用系统“文件”App、Mac 解压都能打开；读的时候只认自己导出的格式。
enum ZipStore {
    static func write(_ entries: [(String, Data)]) throws -> Data {
        var out = Data(), central = Data()
        for (name, data) in entries {
            guard let nameData = name.data(using: .utf8) else { continue }
            let crc = crc32(data), offset = UInt32(out.count)
            let (time, date) = dosNow()
            var local = Data()
            local.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            append16(&local, 20); append16(&local, 0); append16(&local, 0)
            append16(&local, time); append16(&local, date)
            append32(&local, crc); append32(&local, UInt32(data.count)); append32(&local, UInt32(data.count))
            append16(&local, UInt16(nameData.count)); append16(&local, 0)
            local.append(nameData); local.append(data)
            out.append(local)
            var c = Data()
            c.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            append16(&c, 20); append16(&c, 20); append16(&c, 0); append16(&c, 0)
            append16(&c, time); append16(&c, date)
            append32(&c, crc); append32(&c, UInt32(data.count)); append32(&c, UInt32(data.count))
            append16(&c, UInt16(nameData.count)); append16(&c, 0); append16(&c, 0)
            append16(&c, 0); append16(&c, 0); append32(&c, 0); append32(&c, offset)
            c.append(nameData)
            central.append(c)
        }
        var end = Data()
        end.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        append16(&end, 0); append16(&end, 0)
        append16(&end, UInt16(entries.count)); append16(&end, UInt16(entries.count))
        append32(&end, UInt32(central.count)); append32(&end, UInt32(out.count)); append16(&end, 0)
        out.append(central); out.append(end)
        return out
    }

    static func read(_ zip: Data) throws -> [String: Data] {
        // 从尾部找 EOCD
        guard zip.count >= 22 else { throw LocalBackup.BackupError.noBackupJson }
        var eocd: Int?
        for i in stride(from: zip.count - 22, through: max(0, zip.count - 65557), by: -1) {
            if zip[i] == 0x50, zip[i + 1] == 0x4B, zip[i + 2] == 0x05, zip[i + 3] == 0x06 { eocd = i; break }
        }
        guard let eocd else { throw LocalBackup.BackupError.noBackupJson }
        let count = Int(read16(zip, eocd + 10)), cdOffset = Int(read32(zip, eocd + 16))
        var out: [String: Data] = [:], pos = cdOffset
        for _ in 0..<count {
            guard pos + 46 <= zip.count, zip[pos] == 0x50, zip[pos + 1] == 0x4B, zip[pos + 2] == 0x01, zip[pos + 3] == 0x02 else { break }
            let method = read16(zip, pos + 10), compSize = Int(read32(zip, pos + 20))
            let nameLen = Int(read16(zip, pos + 28)), extraLen = Int(read16(zip, pos + 30)), commentLen = Int(read16(zip, pos + 32))
            let localOffset = Int(read32(zip, pos + 42))
            guard let name = String(data: zip[pos + 46..<pos + 46 + nameLen], encoding: .utf8) else { break }
            // 本地头：跳过名字和扩展区，取数据（只支持 stored，method 0）
            guard localOffset + 30 <= zip.count else { break }
            let lNameLen = Int(read16(zip, localOffset + 26)), lExtraLen = Int(read16(zip, localOffset + 28))
            let dataStart = localOffset + 30 + lNameLen + lExtraLen
            guard dataStart + compSize <= zip.count else { throw LocalBackup.BackupError.noBackupJson }
            let raw = Data(zip[dataStart..<dataStart + compSize])
            switch method {
            case 0:
                out[name] = raw
            case 8:
                // 被系统“压缩”过的 zip 用 deflate：Foundation 的 .zlib 吃的就是 zip 里的裸 deflate 流
                guard let inflated = try? (raw as NSData).decompressed(using: .zlib) else {
                    throw LocalBackup.BackupError.unsupportedCompression
                }
                out[name] = inflated as Data
            default:
                throw LocalBackup.BackupError.unsupportedCompression
            }
            pos += 46 + nameLen + extraLen + commentLen
        }
        return out
    }

    private static func append16(_ d: inout Data, _ v: UInt16) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8)) }
    private static func append32(_ d: inout Data, _ v: UInt32) {
        for i in 0..<4 { d.append(UInt8((v >> (i * 8)) & 0xFF)) }
    }
    private static func read16(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[o]) | (UInt16(d[o + 1]) << 8) }
    private static func read32(_ d: Data, _ o: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | (UInt32(d[o + $1]) << ($1 * 8)) }
    }
    private static func dosNow() -> (UInt16, UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: .now)
        let time = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        let date = UInt16((((c.year ?? 1980) - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
        return (time, date)
    }
    private static func crc32(_ data: Data) -> UInt32 {
        var table: [UInt32] = []
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
            table.append(c)
        }
        var crc: UInt32 = 0xFFFFFFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}
