import Foundation

/// BODYSTRUCTURE 分段信息：只取正文用，不取附件
struct BodyPart: Sendable {
    var section: String
    var mime: String          // 如 text/html、image/png
    var size: Int
    var encoding: String      // 7BIT / base64 / quoted-printable
    var charset: String?
    var disposition: String?  // attachment / inline
    var filename: String?
    var contentID: String?
    var isAttachment: Bool { disposition?.lowercased() == "attachment" || (filename != nil && !mime.hasPrefix("text/")) }
    var isInlineImage: Bool { mime.hasPrefix("image/") && contentID != nil && !isAttachment }
}

/// 极简 BODYSTRUCTURE 解析器：只解析出文本分段、附件名、内嵌图片 id。
/// 任何解析失败都返回 nil，调用方回落到整封 BODY.PEEK[]，绝不因为解析错而读不出邮件。
enum BodyStructure {
    enum Node { case list([Node]), atom(String), quoted(String), nilValue }

    static func parse(_ raw: String) -> [BodyPart]? {
        var tokens: [Token] = []
        var i = raw.startIndex
        while i < raw.endIndex {
            let c = raw[i]
            if c == " " || c == "\t" || c == "\r" || c == "\n" { i = raw.index(after: i); continue }
            if c == "(" { tokens.append(.lparen); i = raw.index(after: i); continue }
            if c == ")" { tokens.append(.rparen); i = raw.index(after: i); continue }
            if c == "\"" {
                var s = "", j = raw.index(after: i)
                while j < raw.endIndex, raw[j] != "\"" {
                    if raw[j] == "\\", raw.index(after: j) < raw.endIndex { s.append(raw[raw.index(after: j)]); j = raw.index(after: j) }
                    else { s.append(raw[j]) }
                    j = raw.index(after: j)
                }
                tokens.append(.quoted(s)); i = j < raw.endIndex ? raw.index(after: j) : j; continue
            }
            var j = i
            while j < raw.endIndex, !" ()\"".contains(raw[j]) { j = raw.index(after: j) }
            let w = String(raw[i..<j])
            tokens.append(w.uppercased() == "NIL" ? .nilValue : .atom(w))
            i = j
        }
        var pos = 0
        guard let top = parseNode(tokens, &pos), case .list(let children) = top else { return nil }
        var out: [BodyPart] = []
        collect(children, prefix: "", into: &out)
        return out.isEmpty ? nil : out
    }

    private enum Token { case lparen, rparen, quoted(String), atom(String), nilValue }

    private static func parseNode(_ t: [Token], _ pos: inout Int) -> Node? {
        guard pos < t.count else { return nil }
        switch t[pos] {
        case .lparen:
            pos += 1; var kids: [Node] = []
            while pos < t.count {
                if case .rparen = t[pos] { pos += 1; return .list(kids) }
                guard let n = parseNode(t, &pos) else { return nil }
                kids.append(n)
            }
            return nil
        case .rparen: return nil
        case .quoted(let s): pos += 1; return .atom(s)
        case .atom(let s): pos += 1; return .atom(s)
        case .nilValue: pos += 1; return .nilValue
        }
    }

    private static func str(_ n: Node?) -> String? {
        guard let n else { return nil }
        if case .atom(let s) = n { return s }
        return nil
    }

    private static func params(_ n: Node?) -> [String: String] {
        guard let n, case .list(let kids) = n else { return [:] }
        var d: [String: String] = [:]
        var i = 0
        while i + 1 < kids.count {
            if let k = str(kids[i]), let v = str(kids[i + 1]) { d[k.uppercased()] = v }
            i += 2
        }
        return d
    }

    private static func collect(_ children: [Node], prefix: String, into out: inout [BodyPart]) {
        guard !children.isEmpty else { return }
        // multipart：前几个子节点都是 list，之后是 subtype
        if case .list = children[0] {
            var idx = 0
            for c in children {
                guard case .list(let sub) = c else { break }
                let sec = prefix.isEmpty ? "\(idx + 1)" : "\(prefix).\(idx + 1)"
                collect(sub, prefix: sec, into: &out)
                idx += 1
            }
            return
        }
        // singlepart：type subtype params id description encoding size [lines] [disposition...]
        guard let type = str(children[0]), let subtype = str(children[1]) else { return }
        if type.uppercased() == "MESSAGE" { return }  // message/rfc822：结构复杂，直接回落整封
        let p = params(children.count > 2 ? children[2] : nil)
        let cid = str(children.count > 3 ? children[3] : nil)
        let enc = str(children.count > 5 ? children[5] : nil) ?? ""
        let size = Int(str(children.count > 6 ? children[6] : nil) ?? "") ?? 0
        // disposition：扫描剩余子节点里第一个以 attachment/inline 开头的 list
        var disp: String?, dispParams: [String: String] = [:]
        for c in children.dropFirst(7) {
            if case .list(let d) = c, let first = str(d.first), ["ATTACHMENT", "INLINE"].contains(first.uppercased()) {
                disp = first; dispParams = params(d.count > 1 ? d[1] : nil); break
            }
        }
        let filename = dispParams["FILENAME"] ?? dispParams["NAME"] ?? p["NAME"]
        out.append(BodyPart(
            section: prefix,
            mime: "\(type.lowercased())/\(subtype.lowercased())",
            size: size, encoding: enc, charset: p["CHARSET"],
            disposition: disp, filename: filename,
            contentID: cid.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }.flatMap { $0.isEmpty ? nil : $0 }
        ))
    }
}
