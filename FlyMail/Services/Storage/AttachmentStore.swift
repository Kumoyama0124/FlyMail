import Foundation
import CryptoKit

/// 收到的附件缓存在 Caches 目录（系统空间不足时可能被清理，需要时会重新下载）
enum AttachmentStore {
    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Attachments", isDirectory: true)
    }

    static func directory(accountID: UUID, folder: String, uidValidity: UInt32, uid: UInt32) -> URL {
        let key = SHA256.hash(data: Data("\(accountID)|\(folder)|\(uidValidity)|\(uid)".utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key, isDirectory: true)
    }

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let s = name.components(separatedBy: bad).joined(separator: "_")
        return s.isEmpty ? "附件" : s
    }

    /// 写入并返回（去重后的）文件名列表
    static func save(_ items: [AttachmentData], accountID: UUID, folder: String, uidValidity: UInt32, uid: UInt32) -> [String] {
        let dir = directory(accountID: accountID, folder: folder, uidValidity: uidValidity, uid: uid)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var names: [String] = []
        for a in items {
            var name = sanitize(a.filename)
            var n = 1
            while names.contains(name) {
                n += 1
                let ext = (name as NSString).pathExtension, base = (sanitize(a.filename) as NSString).deletingPathExtension
                name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            }
            try? a.data.write(to: dir.appendingPathComponent(name), options: .atomic)
            names.append(name)
        }
        return names
    }

    static func url(accountID: UUID, folder: String, uidValidity: UInt32, uid: UInt32, name: String) -> URL? {
        directory(accountID: accountID, folder: folder, uidValidity: uidValidity, uid: uid).appendingPathComponent(name)
    }
}
