import Foundation

struct IMAPFolderInfo { let path: String; let name: String; let flags: [String]; let delimiter: String }
struct IMAPHeader { let uid: UInt32; let flags: [String]; let header: Data; var size: Int = 0 }
struct IMAPSelectInfo { var exists = 0; var uidValidity: UInt32 = 0; var uidNext: UInt32 = 0 }

/// 一条 IMAP 响应行；literal 内容拼在 literals 里
struct IMAPLine { var text: String; var literals: [Data] }

/// 极简 IMAP4rev1 客户端（RFC 3501），只实现客户端所需命令。
actor IMAPClient {
    nonisolated private let conn: LineConnection
    private var tagCounter = 0
    private var caps: Set<String>?
    private var lastTagged = ""

    init(host: String, port: Int, tls: Bool) {
        conn = LineConnection(host: host, port: port, tls: tls)
    }

    func connect() async throws {
        let greet = try await readResponseLine()
        guard greet.text.hasPrefix("* OK") || greet.text.hasPrefix("* PREAUTH") else {
            throw MailNetError.protocolError(greet.text)
        }
    }

    func login(user: String, password: String) async throws {
        _ = try await command("LOGIN \(quote(user)) \(quote(password))")
        // 网易系邮箱要求发送 ID，否则 SELECT 会报 Unsafe Login
        _ = try? await command("ID (\"name\" \"FlyMail\" \"version\" \"1.0\" \"vendor\" \"FlyMail\")")
    }

    func authenticateXOAuth2(user: String, accessToken: String) async throws {
        let raw = "user=\(user)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
        _ = try await command("AUTHENTICATE XOAUTH2 \(Data(raw.utf8).base64EncodedString())")
    }

    func list() async throws -> [IMAPFolderInfo] {
        let lines = try await command("LIST \"\" \"*\"")
        var out: [IMAPFolderInfo] = []
        for l in lines where l.text.hasPrefix("* LIST") {
            // * LIST (\HasNoChildren) "/" "INBOX"
            let t = l.text
            guard let fo = t.firstIndex(of: "("), let fc = t.firstIndex(of: ")") else { continue }
            let flags = t[t.index(after: fo)..<fc].split(separator: " ").map(String.init)
            var rest = t[t.index(after: fc)...].trimmingCharacters(in: .whitespaces)
            let delim: String
            if rest.hasPrefix("NIL") { delim = ""; rest = String(rest.dropFirst(3)) }
            else { let parts = rest.dropFirst().split(separator: "\"", maxSplits: 1); delim = parts.first.map(String.init) ?? "/"; rest = parts.count > 1 ? String(parts[1].dropFirst()) : "" }
            var path = rest.trimmingCharacters(in: .whitespaces)
            if let lit = l.literals.first { path = String(decoding: lit, as: UTF8.self) }
            if path.hasPrefix("\"") { path = String(path.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"") }
            if flags.contains(where: { $0.caseInsensitiveCompare("\\Noselect") == .orderedSame }) { continue }
            let decoded = ModifiedUTF7.decode(path)
            let name = delim.isEmpty ? decoded : (decoded.components(separatedBy: delim).last ?? decoded)
            out.append(.init(path: path, name: name, flags: flags, delimiter: delim))
        }
        return out
    }

    func select(_ path: String, readOnly: Bool = false) async throws -> IMAPSelectInfo {
        let lines = try await command("\(readOnly ? "EXAMINE" : "SELECT") \(quote(path))")
        var info = IMAPSelectInfo()
        for l in lines {
            let t = l.text
            if t.hasSuffix(" EXISTS"), let n = Int(t.split(separator: " ")[1]) { info.exists = n }
            if let v = bracketNumber(t, key: "UIDVALIDITY") { info.uidValidity = v }
            if let v = bracketNumber(t, key: "UIDNEXT") { info.uidNext = v }
        }
        return info
    }

    func uidSearch(_ criteria: String) async throws -> [UInt32] {
        let lines = try await command("UID SEARCH \(criteria)")
        return lines.filter { $0.text.hasPrefix("* SEARCH") }
            .flatMap { $0.text.dropFirst(8).split(separator: " ").compactMap { UInt32($0) } }
    }

    /// 拉取头部（不标记已读）
    func fetchHeaders(uids: [UInt32]) async throws -> [IMAPHeader] {
        guard !uids.isEmpty else { return [] }
        let set = uids.map(String.init).joined(separator: ",")
        let lines = try await command("UID FETCH \(set) (UID FLAGS RFC822.SIZE BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID REPLY-TO X-SPAM-FLAG X-SPAM-STATUS X-SPAM X-QQ-SPAM AUTHENTICATION-RESULTS CONTENT-TYPE)])")
        return lines.compactMap { l in
            guard l.text.hasPrefix("*"), l.text.contains("FETCH"), let uid = fieldNumber(l.text, key: "UID") else { return nil }
            return IMAPHeader(uid: uid, flags: parseFlags(l.text), header: l.literals.first ?? Data(), size: Int(fieldNumber(l.text, key: "RFC822.SIZE") ?? 0))
        }
    }

    func fetchBody(uid: UInt32) async throws -> Data {
        let lines = try await command("UID FETCH \(uid) (BODY.PEEK[])")
        return lines.first { !$0.literals.isEmpty }?.literals.first ?? Data()
    }

    /// 只拉 UID + FLAGS（不拉头部、不拉正文），用于同步时核对已读/星标：
    /// 以前同步只给新邮件设 Seen，旧邮件在别处（苹果邮件、网页版）读过之后，
    /// 本地永远还是未读，侧边栏就会一直挂着一个“幻影 1”。
    func fetchFlags(uids: [UInt32]) async throws -> [(uid: UInt32, flags: [String])] {
        guard !uids.isEmpty else { return [] }
        let set = uids.map(String.init).joined(separator: ",")
        let lines = try await command("UID FETCH \(set) (UID FLAGS)")
        return lines.compactMap { l in
            guard l.text.hasPrefix("*"), l.text.contains("FETCH"), let uid = fieldNumber(l.text, key: "UID") else { return nil }
            return (uid: uid, flags: parseFlags(l.text))
        }
    }

    /// 拉取 BODYSTRUCTURE 原文（不拉正文），供分段取文本用
    func fetchStructure(uid: UInt32) async throws -> String {
        let lines = try await command("UID FETCH \(uid) (BODYSTRUCTURE)")
        guard let l = lines.first(where: { $0.text.contains("BODYSTRUCTURE") }) else { return "" }
        // BODYSTRUCTURE 在 "BODYSTRUCTURE " 之后，直到行尾（可能带 ") " 后缀）
        guard let r = l.text.range(of: "BODYSTRUCTURE ") else { return "" }
        return String(l.text[r.upperBound...])
    }

    /// 拉取指定分段的 MIME 头（编码、字符集）和正文数据，分开拉两次，
    /// 这样每次响应只有一个 literal，不用处理多 literal 的拼接。
    func fetchSectionMIME(uid: UInt32, section: String) async throws -> Data {
        let lines = try await command("UID FETCH \(uid) (BODY.PEEK[\(section).MIME])")
        return lines.first { !$0.literals.isEmpty }?.literals.first ?? Data()
    }

    func fetchSection(uid: UInt32, section: String) async throws -> Data {
        let lines = try await command("UID FETCH \(uid) (BODY.PEEK[\(section)])")
        return lines.first { !$0.literals.isEmpty }?.literals.first ?? Data()
    }

    func setSeen(uid: UInt32, _ seen: Bool) async throws {
        _ = try await command("UID STORE \(uid) \(seen ? "+" : "-")FLAGS.SILENT (\\Seen)")
    }

    /// APPEND，返回新 UID（服务器支持 UIDPLUS 时）
    @discardableResult
    func append(folder: String, message: Data, flags: String = "\\Seen") async throws -> UInt32? {
        let tag = nextTag()
        try await conn.write("\(tag) APPEND \(quote(folder)) (\(flags)) {\(message.count)}\r\n")
        let cont = try await readResponseLine()
        guard cont.text.hasPrefix("+") else { throw MailNetError.protocolError(cont.text) }
        try await conn.write(message + Data("\r\n".utf8))
        _ = try await collect(tag: tag)
        if let r = lastTagged.range(of: "[APPENDUID ") {
            let parts = lastTagged[r.upperBound...].split(separator: " ")
            if parts.count >= 2 { return UInt32(parts[1].prefix { $0.isNumber }) }
        }
        return nil
    }

    func capabilities() async throws -> Set<String> {
        if let c = caps { return c }
        let lines = try await command("CAPABILITY")
        var set = Set<String>()
        for l in lines where l.text.hasPrefix("* CAPABILITY") {
            l.text.dropFirst(13).split(separator: " ").forEach { set.insert($0.uppercased()) }
        }
        caps = set
        return set
    }

    func storeFlags(uids: [UInt32], add: Bool, flags: String) async throws {
        guard !uids.isEmpty else { return }
        _ = try await command("UID STORE \(uids.map(String.init).joined(separator: ",")) \(add ? "+" : "-")FLAGS.SILENT (\(flags))")
    }

    /// 删除并清除指定 UID（UIDPLUS 时用 UID EXPUNGE，避免误删别的已标记邮件）
    func expunge(uids: [UInt32]) async throws {
        try await storeFlags(uids: uids, add: true, flags: "\\Deleted")
        if try await capabilities().contains("UIDPLUS") {
            _ = try await command("UID EXPUNGE \(uids.map(String.init).joined(separator: ","))")
        } else {
            _ = try await command("EXPUNGE")
        }
    }

    /// 移动邮件：优先 UID MOVE（RFC 6851），否则 COPY + \Deleted + EXPUNGE
    func move(uids: [UInt32], to folder: String) async throws {
        let set = uids.map(String.init).joined(separator: ",")
        if try await capabilities().contains("MOVE") {
            _ = try await command("UID MOVE \(set) \(quote(folder))")
        } else {
            _ = try await command("UID COPY \(set) \(quote(folder))")
            try await expunge(uids: uids)
        }
    }

    /// 指定 UID 是否仍存在于当前选中的文件夹
    func existingUIDs(_ uids: [UInt32]) async throws -> Set<UInt32> {
        guard !uids.isEmpty else { return [] }
        return Set(try await uidSearch("UID \(uids.map(String.init).joined(separator: ","))"))
    }

    /// 当前文件夹全部 UID 的轻量拉取（用于与本地缓存对账）
    func allUIDs() async throws -> Set<UInt32> { Set(try await uidSearch("ALL")) }

    func create(_ path: String) async throws {
        _ = try await command("CREATE \(quote(path))")
    }

    func searchHeader(_ name: String, _ value: String) async throws -> [UInt32] {
        try await uidSearch("HEADER \(name) \(quote(value))")
    }

    /// IMAP IDLE（RFC 2177）。有新邮件(EXISTS)时返回 true，超时返回 false。
    func idle(seconds: TimeInterval) async throws -> Bool {
        let tag = nextTag()
        try await conn.write("\(tag) IDLE\r\n")
        let cont = try await readResponseLine()
        guard cont.text.hasPrefix("+") else { throw MailNetError.protocolError(cont.text) }
        let deadline = Date.now.addingTimeInterval(seconds)
        var gotNew = false
        while Date.now < deadline && !Task.isCancelled {
            do {
                let line = try await conn.readLine(timeout: max(5, deadline.timeIntervalSinceNow))
                if line.hasSuffix(" EXISTS") || line.contains(" RECENT") { gotNew = true; break }
            } catch {
                if Date.now >= deadline.addingTimeInterval(-5) { break }   // 读超时 = 到时
                throw error
            }
        }
        try await conn.write("DONE\r\n")
        _ = try await collect(tag: tag)
        return gotNew
    }

    /// 允许其他任务强制断开（用于停止 IDLE）
    nonisolated func forceClose() { conn.close() }

    func logout() async {
        _ = try? await command("LOGOUT")
        conn.close()
    }

    // MARK: - 底层

    private func nextTag() -> String { tagCounter += 1; return "A\(tagCounter)" }

    @discardableResult
    private func command(_ cmd: String) async throws -> [IMAPLine] {
        let tag = nextTag()
        try await conn.write("\(tag) \(cmd)\r\n")
        return try await collect(tag: tag)
    }

    private func collect(tag: String) async throws -> [IMAPLine] {
        var lines: [IMAPLine] = []
        while true {
            let l = try await readResponseLine()
            if l.text.hasPrefix(tag + " ") {
                let status = l.text.dropFirst(tag.count + 1)
                lastTagged = String(status)
                guard status.hasPrefix("OK") else { throw MailNetError.protocolError(String(status)) }
                return lines
            }
            if l.text.hasPrefix("+") {   // SASL 失败时服务器会发 continuation，回空行结束
                try await conn.write("\r\n"); continue
            }
            lines.append(l)
        }
    }

    /// 读取一条完整响应（处理 {n} literal）
    private func readResponseLine() async throws -> IMAPLine {
        var text = try await conn.readLine()
        var literals: [Data] = []
        while let n = trailingLiteralLength(text) {
            literals.append(try await conn.readBytes(n))
            text += " \u{0}LIT\u{0} " + (try await conn.readLine())
        }
        return IMAPLine(text: text, literals: literals)
    }

    private func trailingLiteralLength(_ s: String) -> Int? {
        guard s.hasSuffix("}"), let o = s.lastIndex(of: "{") else { return nil }
        return Int(s[s.index(after: o)..<s.index(before: s.endIndex)].trimmingCharacters(in: CharacterSet(charactersIn: "+")))
    }

    private func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func bracketNumber(_ s: String, key: String) -> UInt32? {
        guard let r = s.range(of: "[\(key) ") else { return nil }
        return UInt32(s[r.upperBound...].prefix { $0.isNumber })
    }

    private func fieldNumber(_ s: String, key: String) -> UInt32? {
        guard let r = s.range(of: "\(key) ") else { return nil }
        return UInt32(s[r.upperBound...].prefix { $0.isNumber })
    }

    private func parseFlags(_ s: String) -> [String] {
        guard let r = s.range(of: "FLAGS (") else { return [] }
        return s[r.upperBound...].prefix { $0 != ")" }.split(separator: " ").map(String.init)
    }
}

/// IMAP 修改版 UTF-7 文件夹名解码（RFC 3501 §5.1.3）
enum ModifiedUTF7 {
    static func encode(_ s: String) -> String {
        var out = "", pending: [UInt16] = []
        func flush() {
            guard !pending.isEmpty else { return }
            var d = Data()
            for u in pending { d.append(UInt8(u >> 8)); d.append(UInt8(u & 0xff)) }
            out += "&" + d.base64EncodedString().replacingOccurrences(of: "/", with: ",").replacingOccurrences(of: "=", with: "") + "-"
            pending = []
        }
        for scalar in s.unicodeScalars {
            if scalar.value >= 0x20 && scalar.value <= 0x7e {
                flush(); out += scalar == "&" ? "&-" : String(scalar)
            } else { pending.append(contentsOf: Array(String(scalar).utf16)) }
        }
        flush()
        return out
    }

    static func decode(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let end = s[i...].firstIndex(of: "-") {
                let chunk = s[s.index(after: i)..<end]
                if chunk.isEmpty { out.append("&") }
                else {
                    var b64 = chunk.replacingOccurrences(of: ",", with: "/")
                    while b64.count % 4 != 0 { b64 += "=" }
                    if let d = Data(base64Encoded: b64) {
                        out += String(data: d, encoding: .utf16BigEndian) ?? String(chunk)
                    }
                }
                i = s.index(after: end)
            } else { out.append(c); i = s.index(after: i) }
        }
        return out
    }
}
