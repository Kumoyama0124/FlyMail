import Foundation

/// 轻量本地垃圾邮件评分（规则 + 黑白名单 + 从用户操作中学习）
enum SpamFilter {
    private static let d = UserDefaults.standard
    static let thresholdKey = "spam.threshold", autoMoveKey = "spam.autoMove"
    static let blockKey = "spam.blockList", allowKey = "spam.allowList"

    static var threshold: Int { d.object(forKey: thresholdKey) as? Int ?? 50 }
    static var autoMove: Bool { d.bool(forKey: autoMoveKey) }
    static var blockList: [String] { d.stringArray(forKey: blockKey) ?? [] }
    static var allowList: [String] { d.stringArray(forKey: allowKey) ?? [] }

    static func add(_ entry: String, toBlock: Bool) {
        let e = entry.lowercased().trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty else { return }
        var add = toBlock ? blockList : allowList, other = toBlock ? allowList : blockList
        if !add.contains(e) { add.append(e) }
        other.removeAll { $0 == e }
        d.set(add, forKey: toBlock ? blockKey : allowKey)
        d.set(other, forKey: toBlock ? allowKey : blockKey)
    }

    static func remove(_ entry: String, fromBlock: Bool) {
        let key = fromBlock ? blockKey : allowKey
        d.set((d.stringArray(forKey: key) ?? []).filter { $0 != entry }, forKey: key)
    }

    /// 学习：标记垃圾 → 发件人入黑名单；不是垃圾 → 入白名单
    static func learn(from: String, isSpam: Bool) {
        if let addr = MIMEParser.addresses(from).first { add(addr, toBlock: isSpam) }
    }

    private static func matches(_ addr: String, _ list: [String]) -> Bool {
        let a = addr.lowercased(), domain = a.split(separator: "@").last.map(String.init) ?? ""
        return list.contains { $0 == a || $0 == domain || $0 == "@" + domain || (domain.hasSuffix("." + $0.trimmingCharacters(in: CharacterSet(charactersIn: "@")))) }
    }

    private static let keywords = [
        "发票", "代开", "贷款", "中奖", "恭喜您", "免费领取", "刷单", "兼职日结", "博彩", "澳门", "赌场", "加微信", "低价出售", "退订回T",
        "viagra", "casino", "lottery", "winner", "free money", "act now", "limited time", "click here", "verify your account",
        "urgent", "bitcoin", "crypto investment", "100% free", "unsubscribe",
    ]

    static func evaluate(headers h: [String: String], subject: String, from: String, text: String = "", html: String? = nil) -> (Int, [String]) {
        let addr = MIMEParser.addresses(from).first ?? ""
        let domain = addr.split(separator: "@").last.map { String($0).lowercased() } ?? ""
        if matches(addr, allowList) { return (0, []) }
        var score = 0, reasons: [String] = []
        func hit(_ s: Int, _ r: String) { score += s; reasons.append(r) }

        if matches(addr, blockList) { hit(100, "发件人在黑名单中") }
        if (h["x-spam-flag"] ?? "").lowercased().hasPrefix("yes") { hit(60, "服务器标记为垃圾邮件 (X-Spam-Flag)") }
        if (h["x-spam-status"] ?? "").lowercased().hasPrefix("yes") { hit(60, "服务器标记为垃圾邮件 (X-Spam-Status)") }
        for k in ["x-qq-spam", "x-spam"] {
            let v = (h[k] ?? "").lowercased()
            if v.contains("true") || v.hasPrefix("yes") || v.contains("spam") { hit(50, "服务器垃圾标记 (\(k))") }
        }
        let auth = (h["authentication-results"] ?? "").lowercased()
        if auth.contains("spf=fail") || auth.contains("spf=softfail") { hit(15, "SPF 校验失败") }
        if auth.contains("dkim=fail") { hit(15, "DKIM 签名校验失败") }
        if auth.contains("dmarc=fail") { hit(25, "DMARC 校验失败") }

        // 显示名里写了别的邮箱地址（冒充）
        let display = displayName(from).lowercased()
        if display.contains("@"), let dd = display.split(separator: "@").last.map({ String($0).trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }),
           !dd.isEmpty, !domain.isEmpty, !domain.hasSuffix(dd), !dd.hasSuffix(domain) {
            hit(20, "显示名与真实发件地址不符")
        }
        if let rt = h["reply-to"], let rta = MIMEParser.addresses(rt).first, let rd = rta.split(separator: "@").last,
           !domain.isEmpty, rd.lowercased() != domain {
            hit(10, "回复地址与发件域名不同")
        }

        let body = (subject + " " + text).lowercased()
        var kw = 0
        for k in keywords where body.contains(k.lowercased()) { kw += 8 }
        if kw > 0 { hit(min(kw, 40), "包含常见垃圾邮件词语") }
        if subject.filter({ $0 == "!" || $0 == "！" }).count >= 3 { hit(5, "主题含大量感叹号") }

        if let html, linkMismatch(html) { hit(20, "链接文字与实际网址域名不一致") }
        return (score, reasons)
    }

    /// <a href="https://evil.com">https://bank.com</a> 这类
    static func linkMismatch(_ html: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: #"<a[^>]+href\s*=\s*["']https?://([^/"'\s:]+)[^>]*>([^<]{4,200})</a>"#, options: .caseInsensitive) else { return false }
        let ns = html as NSString
        for m in re.matches(in: html, range: NSRange(location: 0, length: min(ns.length, 200_000))) {
            let real = ns.substring(with: m.range(at: 1)).lowercased()
            let shown = ns.substring(with: m.range(at: 2)).lowercased()
            guard let r = shown.range(of: #"(https?://)?(www\.)?[a-z0-9-]+(\.[a-z0-9-]+)+"#, options: .regularExpression) else { continue }
            let shownHost = shown[r].replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "www.", with: "")
            if !real.hasSuffix(shownHost) && !shownHost.hasSuffix(real.replacingOccurrences(of: "www.", with: "")) { return true }
        }
        return false
    }
}
