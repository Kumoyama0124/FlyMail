import Foundation

struct ParsedMessage {
    var headers: [String: String] = [:]
    var text = ""
    var html: String?
    var attachments: [AttachmentData] = []
    /// cid → (mime, data)
    var inline: [String: (String, Data)] = [:]
}

/// 简化的 MIME 解析器：头部解码（RFC 2047）、multipart、base64/QP、常见中文字符集。
enum MIMEParser {
    static func parseHeaders(_ data: Data) -> [String: String] {
        let raw = String(decoding: data, as: UTF8.self)
        return parseHeaderBlock(raw)
    }

    static func parseHeaderBlock(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        var current: (String, String)?
        for line in raw.components(separatedBy: "\r\n").flatMap({ $0.components(separatedBy: "\n") }) {
            if line.isEmpty { break }
            if line.first == " " || line.first == "\t", var cur = current {
                cur.1 += " " + line.trimmingCharacters(in: .whitespaces); current = cur
            } else if let idx = line.firstIndex(of: ":") {
                if let (k, v) = current { result[k] = decodeWords(v) }
                current = (line[..<idx].lowercased(), line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces))
            }
        }
        if let (k, v) = current { result[k] = decodeWords(v) }
        return result
    }

    static func parse(_ data: Data) -> ParsedMessage {
        var msg = ParsedMessage()
        let (hdrRaw, body) = split(data)
        msg.headers = parseHeaderBlock(hdrRaw)
        walk(headers: msg.headers, body: body, into: &msg)
        if var h = msg.html {
            // 内嵌图片 cid: → data: URI
            for (cid, (mime, data)) in msg.inline {
                h = h.replacingOccurrences(of: "cid:\(cid)", with: "data:\(mime);base64,\(data.base64EncodedString())")
            }
            msg.html = h
            if msg.text.isEmpty { msg.text = stripHTML(h) }
        }
        return msg
    }

    private static func split(_ data: Data) -> (String, Data) {
        for sep in [Data("\r\n\r\n".utf8), Data("\n\n".utf8)] {
            if let r = data.range(of: sep) {
                return (String(decoding: data[..<r.lowerBound], as: UTF8.self), Data(data[r.upperBound...]))
            }
        }
        return (String(decoding: data, as: UTF8.self), Data())
    }

    private static func walk(headers: [String: String], body: Data, into msg: inout ParsedMessage) {
        let ctype = headers["content-type"] ?? "text/plain"
        let params = parameters(ctype)
        let mime = ctype.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"
        if mime.hasPrefix("multipart/"), let boundary = params["boundary"] {
            for part in splitMultipart(body, boundary: boundary) {
                let (h, b) = split(part)
                walk(headers: parseHeaderBlock(h), body: b, into: &msg)
            }
            return
        }
        let decoded = decodeTransfer(body, encoding: headers["content-transfer-encoding"]?.lowercased() ?? "")
        let disp = headers["content-disposition"]?.lowercased() ?? ""
        let filename = parameters(headers["content-disposition"] ?? "")["filename"] ?? params["name"]
        if let cidRaw = headers["content-id"], mime.hasPrefix("image/"), !disp.hasPrefix("attachment") {
            let cid = cidRaw.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            msg.inline[cid] = (mime, decoded)
        } else if disp.hasPrefix("attachment") || (filename != nil && !mime.hasPrefix("text/")) {
            msg.attachments.append(AttachmentData(filename: filename.map(decodeWords) ?? "附件", mimeType: mime, data: decoded))
        } else if mime == "text/html" {
            msg.html = (msg.html ?? "") + decodeCharset(decoded, params["charset"])
        } else if mime.hasPrefix("text/") {
            msg.text += decodeCharset(decoded, params["charset"])
        }
    }

    private static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let delim = Data("--\(boundary)".utf8)
        var parts: [Data] = []
        var search = body.startIndex
        var start: Data.Index?
        while let r = body.range(of: delim, in: search..<body.endIndex) {
            if let s = start { parts.append(Data(body[s..<r.lowerBound])) }
            var next = r.upperBound
            if body[next...].starts(with: Data("--".utf8)) { break }
            while next < body.endIndex, body[next] == 13 || body[next] == 10 { next = body.index(after: next) }
            start = next; search = next
        }
        return parts
    }

    static func parameters(_ header: String) -> [String: String] {
        var out: [String: String] = [:]
        for p in header.split(separator: ";").dropFirst() {
            let kv = p.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            var v = kv[1].trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") { v = String(v.dropFirst().dropLast()) }
            var k = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            if k.hasSuffix("*") {   // RFC 2231: utf-8''xxx
                k.removeLast()
                if let r = v.range(of: "''") { v = String(v[r.upperBound...]).removingPercentEncoding ?? v }
            }
            out[k] = v
        }
        return out
    }

    static func decodeTransfer(_ data: Data, encoding: String) -> Data {
        switch encoding {
        case "base64":
            let s = String(decoding: data, as: UTF8.self).components(separatedBy: .whitespacesAndNewlines).joined()
            return Data(base64Encoded: s, options: .ignoreUnknownCharacters) ?? data
        case "quoted-printable":
            return quotedPrintable(String(decoding: data, as: UTF8.self))
        default: return data
        }
    }

    static func quotedPrintable(_ s: String, underscoreIsSpace: Bool = false) -> Data {
        var out = Data()
        let bytes = Array(s.utf8)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "=") {
                if i + 1 < bytes.count, bytes[i + 1] == 13 || bytes[i + 1] == 10 {
                    i += 1; while i < bytes.count, bytes[i] == 13 || bytes[i] == 10 { i += 1 }; continue
                }
                if i + 2 < bytes.count, let v = UInt8(String(decoding: bytes[i+1...i+2], as: UTF8.self), radix: 16) {
                    out.append(v); i += 3; continue
                }
            }
            out.append(underscoreIsSpace && b == UInt8(ascii: "_") ? 32 : b); i += 1
        }
        return out
    }

    static func decodeCharset(_ data: Data, _ charset: String?) -> String {
        let cs = (charset ?? "utf-8").lowercased()
        let enc: String.Encoding
        switch cs {
        case "gbk", "gb2312", "gb18030", "x-gbk":
            enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "big5": enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        case "iso-8859-1", "latin1": enc = .isoLatin1
        case "us-ascii": enc = .ascii
        default: enc = .utf8
        }
        return String(data: data, encoding: enc) ?? String(decoding: data, as: UTF8.self)
    }

    /// RFC 2047 =?charset?B|Q?text?=
    static func decodeWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let pattern = #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        // 相邻编码词之间的空白应被忽略
        let compact = s.replacingOccurrences(of: #"\?=\s+=\?"#, with: "?==?", options: .regularExpression)
        let ns = compact as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: compact, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let cs = ns.substring(with: m.range(at: 1)), mode = ns.substring(with: m.range(at: 2)).uppercased()
            let text = ns.substring(with: m.range(at: 3))
            let data = mode == "B" ? (Data(base64Encoded: text, options: .ignoreUnknownCharacters) ?? Data())
                                   : quotedPrintable(text, underscoreIsSpace: true)
            result += decodeCharset(data, cs)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    static func parseDate(_ s: String?) -> Date {
        guard let s else { return .now }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let cleaned = s.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
        for fmt in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"] {
            f.dateFormat = fmt
            if let d = f.date(from: cleaned) { return d }
        }
        return .now
    }

    static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: #"<(style|script)[^>]*>[\s\S]*?</\1>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从 "Name <a@b>, c@d" 中提取邮箱地址
    static func addresses(_ s: String) -> [String] {
        s.split(separator: ",").compactMap { part in
            let p = part.trimmingCharacters(in: .whitespaces)
            if let l = p.lastIndex(of: "<"), let r = p.lastIndex(of: ">"), l < r { return String(p[p.index(after: l)..<r]) }
            return p.contains("@") ? p : nil
        }
    }
}
