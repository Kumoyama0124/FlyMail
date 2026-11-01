import UIKit
import CryptoKit
import WebKit
import ImageIO

/// 发件人头像解析：BIMI → 品牌映射/网站图标 → Gravatar → 首字母（由视图兜底）
/// 带内存 + 磁盘缓存（成功 7 天、失败 1 天）
actor AvatarService {
    static let shared = AvatarService()
    /// 缓存版本：变更解析逻辑后递增，旧的负缓存一并作废
    /// v3：图标源改为 Oasisic 512×512 优先，旧的 mini/网站图标缓存（网易带锁、189 粗糙等）全部作废
    /// v4：沃邮箱图标改走中国联通官网 10010.com，旧的“沃”字标负缓存作废
    /// v5：沃邮箱图标改用中国联通 APP 图标（App Store 官方图），旧的网站小图标缓存作废
    private static let cacheVersion = "v5"

    private let memory = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private let positiveTTL: TimeInterval = 7 * 86400
    private let negativeTTL: TimeInterval = 3600
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5
        c.timeoutIntervalForResource = 8
        c.httpCookieAcceptPolicy = .never
        c.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"]
        return URLSession(configuration: c)
    }()

    private var dir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Avatars-" + Self.cacheVersion, isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.removeItem(at: base.appendingPathComponent("Avatars"))
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    /// 一次解析的状态：遇到网络错误时不写负缓存（避免离线/超时把头像“拉黑”）
    final class Attempt: @unchecked Sendable { var networkError = false }

    func image(for email: String, name: String = "") async -> UIImage? {
        let key = email.lowercased()
        if let m = memory.object(forKey: key as NSString) { return m }
        let hash = Self.hex(SHA256.hash(data: Data(key.utf8)))
        let file = dir.appendingPathComponent(hash + ".png"), neg = dir.appendingPathComponent(hash + ".none")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path), let d = attrs[.modificationDate] as? Date,
           Date.now.timeIntervalSince(d) < positiveTTL, let img = UIImage(contentsOfFile: file.path) {
            memory.setObject(img, forKey: key as NSString); return img
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: neg.path), let d = attrs[.modificationDate] as? Date,
           Date.now.timeIntervalSince(d) < negativeTTL { return nil }
        if let t = inflight[key] { return await t.value }
        let attempt = Attempt()
        let t = Task { await self.resolve(key, name: name, attempt) }
        inflight[key] = t
        let img = await t.value
        inflight[key] = nil
        if let img, let png = img.pngData() {
            try? png.write(to: file); memory.setObject(img, forKey: key as NSString)
            try? FileManager.default.removeItem(at: neg)
        } else if !attempt.networkError {
            FileManager.default.createFile(atPath: neg.path, contents: Data())
        }
        return img
    }

    func clearCache() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: dir)
    }

    private func resolve(_ email: String, name: String, _ at: Attempt) async -> UIImage? {
        guard let host = email.split(separator: "@").last.map(String.init), !host.isEmpty else { return nil }
        if email.hasPrefix("@") {
            // 服务商卡片：先走 Oasisic 512×512（见 OasisicIcons，网易邮箱无锁、189 高清），
            // 再走 mini 品牌库，失败再走站点图标；最后兜底是首字母
            // 沃邮箱：不用 wo.cn 的站标和 10010.com 的网站小图标，直接用中国联通 APP 图标
            // （App Store 官方图，512×512，远程引用、不打包商标图）；拉不到再回落到网站图标
            if ["wo.cn", "wo.com.cn", "10010.com"].contains(host) {
                if let img = await fetchImage("https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/73/4a/81/734a813f-23c5-0399-9bfc-95edd616256d/AppIcon-0-0-1x_U007epad-0-11-0-85-220.png/512x512bb.jpg", minSize: 128, at) { return img }
                if let img = await fetchImage("https://favicon.im/10010.com?larger=true", minSize: 16, at) { return img }
                if let img = await fetchImage("https://icon.horse/icon/10010.com", minSize: 16, at) { return img }
            }
            if let u = OasisicIcons.url(for: host), let img = await fetchImage(u, minSize: 128, at) { return img }
            if let u = MiniIcons.url(for: host), let img = await fetchImage(u, minSize: 16, at) { return img }
            return await favicon(host, at)
        }
        let org = DomainUtil.orgDomain(host)
        if !DomainUtil.freemail.contains(org) {
            if let u = OasisicIcons.url(for: org), let img = await fetchImage(u, minSize: 128, at) { return img }
            if let u = MiniIcons.url(for: org), let img = await fetchImage(u, minSize: 16, at) { return img }
            if let img = await bimi(org, at) { return img }
            let brand = BrandMap.domain(for: host) ?? BrandMap.domain(for: org) ?? org
            if let u = OasisicIcons.url(for: brand), let img = await fetchImage(u, minSize: 128, at) { return img }
            if let u = MiniIcons.url(for: brand), let img = await fetchImage(u, minSize: 16, at) { return img }
            if let img = await favicon(brand, at) { return img }
        } else if let brand = BrandMap.officialSender(email, name: name, org: org) {
            if let u = OasisicIcons.url(for: brand), let img = await fetchImage(u, minSize: 128, at) { return img }
            if let u = MiniIcons.url(for: brand), let img = await fetchImage(u, minSize: 16, at) { return img }
            if let img = await favicon(brand, at) { return img }
        }
        return await gravatar(email, at)
    }

    // MARK: (a) BIMI via DNS-over-HTTPS（国内优先阿里 / 腾讯 DoH）
    private func bimi(_ domain: String, _ at: Attempt) async -> UIImage? {
        let name = "default._bimi.\(domain)"
        let endpoints = [
            "https://dns.alidns.com/resolve?name=\(name)&type=16",
            "https://doh.pub/resolve?name=\(name)&type=16",
            "https://cloudflare-dns.com/dns-query?name=\(name)&type=TXT",
        ]
        for e in endpoints {
            guard let url = URL(string: e) else { continue }
            var req = URLRequest(url: url)
            req.setValue("application/dns-json", forHTTPHeaderField: "Accept")
            guard let (data, _) = try? await session.data(for: req),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for a in (json["Answer"] as? [[String: Any]]) ?? [] {
                let txt = ((a["data"] as? String) ?? "").replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: " ", with: "")
                guard txt.lowercased().contains("v=bimi1") else { continue }
                for part in txt.split(separator: ";") where part.lowercased().hasPrefix("l=") {
                    guard let u = URL(string: String(part.dropFirst(2))), u.scheme == "https" else { continue }
                    guard let (svg, _) = try? await session.data(from: u), !svg.isEmpty else { at.networkError = true; continue }
                    if let img = await SVGRenderer.render(svg) { return img }
                }
            }
            return nil   // 查询成功但没有 BIMI
        }
        return nil
    }

    // MARK: (c) 网站图标：站点自身优先（国内可达），再试公共图标服务
    private func favicon(_ domain: String, _ at: Attempt) async -> UIImage? {
        for c in ["https://\(domain)/apple-touch-icon.png", "https://www.\(domain)/apple-touch-icon.png"] {
            if let img = await fetchImage(c, minSize: 48, at) { return img }
        }
        if let img = await homepageIcon(domain, at) { return img }
        for c in ["https://\(domain)/favicon.ico", "https://www.\(domain)/favicon.ico",
                  "https://icon.horse/icon/\(domain)", "https://favicon.im/\(domain)?larger=true"] {
            if let img = await fetchImage(c, minSize: 16, at) { return img }
        }
        return nil
    }

    /// 解析首页 <link rel="...icon..." href> 取最大的图标
    private func homepageIcon(_ domain: String, _ at: Attempt) async -> UIImage? {
        var html: String?, base: URL?
        for h in ["https://www.\(domain)/", "https://\(domain)/"] {
            guard let u = URL(string: h) else { continue }
            if let (d, r) = try? await session.data(from: u), (r as? HTTPURLResponse)?.statusCode == 200 {
                html = String(decoding: d.prefix(300_000), as: UTF8.self); base = r.url ?? u; break
            } else { at.networkError = true }
        }
        guard let html, let base else { return nil }
        var cands: [(Int, URL)] = []
        let tagRe = try! NSRegularExpression(pattern: "<link[^>]+>", options: .caseInsensitive)
        for m in tagRe.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            let tag = String(html[Range(m.range, in: html)!])
            let lower = tag.lowercased()
            guard lower.contains("icon"), let href = Self.attr(tag, "href"), let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  url.scheme == "https" || url.scheme == "http" else { continue }
            var score = lower.contains("apple-touch") ? 180 : 32
            if let sz = Self.attr(tag, "sizes"), let n = Int(sz.lowercased().split(separator: "x").first ?? "") { score = n }
            if url.pathExtension.lowercased() == "svg" { score = 10 }
            cands.append((score, url))
        }
        for (_, u) in cands.sorted(by: { $0.0 > $1.0 }).prefix(3) {
            var s = u.absoluteString
            if s.hasPrefix("http://") { s = "https://" + s.dropFirst(7) }   // ATS：只走 https
            if let img = await fetchImage(s, minSize: 16, at) { return img }
        }
        return nil
    }

    static func attr(_ tag: String, _ name: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: name + "\\s*=\\s*[\"']([^\"']+)[\"']", options: .caseInsensitive),
              let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)), let r = Range(m.range(at: 1), in: tag) else { return nil }
        return String(tag[r]).replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: (d) Gravatar / Cravatar（d=404 表示无头像）
    private func gravatar(_ email: String, _ at: Attempt) async -> UIImage? {
        let md5 = Self.hex(Insecure.MD5.hash(data: Data(email.utf8)))
        if let img = await fetchImage("https://cravatar.cn/avatar/\(md5)?s=128&d=404", minSize: 16, at) { return img }
        let sha = Self.hex(SHA256.hash(data: Data(email.utf8)))
        return await fetchImage("https://gravatar.com/avatar/\(sha)?s=128&d=404", minSize: 16, at)
    }

    private func fetchImage(_ s: String, minSize: CGFloat, _ at: Attempt) async -> UIImage? {
        guard let url = URL(string: s) else { return nil }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(from: url) } catch { at.networkError = true; return nil }
        guard (resp as? HTTPURLResponse)?.statusCode == 200, !(resp.mimeType ?? "").contains("html") else { return nil }
        if (resp.mimeType ?? "").contains("svg") || s.lowercased().hasSuffix(".svg") { return await SVGRenderer.render(data) }
        guard let img = Self.largestFrame(data), img.size.width >= minSize else { return nil }
        return img
    }

    /// ICO 可能含多帧（16/32/64），取最大的一帧
    static func largestFrame(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
        var best: CGImage?
        for i in 0..<CGImageSourceGetCount(src) {
            if let c = CGImageSourceCreateImageAtIndex(src, i, nil), c.width > (best?.width ?? 0) { best = c }
        }
        return best.map { UIImage(cgImage: $0) } ?? UIImage(data: data)
    }

    static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }
}

enum DomainUtil {
    static let multiPartSuffixes: Set<String> = ["com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn", "co.uk", "org.uk", "ac.uk",
                                                 "com.hk", "com.tw", "co.jp", "ne.jp", "com.au", "co.kr", "com.sg", "com.br"]
    static let freemail: Set<String> = ["gmail.com", "googlemail.com", "qq.com", "foxmail.com", "163.com", "126.com", "yeah.net",
                                        "outlook.com", "hotmail.com", "live.com", "msn.com", "icloud.com", "me.com", "mac.com",
                                        "yahoo.com", "sina.com", "sina.cn", "sohu.com", "139.com", "189.cn", "aliyun.com", "proton.me", "protonmail.com"]

    /// mail.notice.weibo.com → weibo.com；service.sina.com.cn → sina.com.cn
    static func orgDomain(_ host: String) -> String {
        let parts = host.lowercased().split(separator: ".").map(String.init)
        guard parts.count > 2 else { return parts.joined(separator: ".") }
        let last2 = parts.suffix(2).joined(separator: ".")
        return multiPartSuffixes.contains(last2) ? parts.suffix(3).joined(separator: ".") : last2
    }
}

/// 最优图标库（Hawaiine/Oasisic-Icons，公开仓库，仅远程引用、不打包商标图片）：
/// 全部 512×512 PNG、CI 校验，优先于 mini。已逐一核对：
/// 网易用 NetEaseMail（红底邮字、无锁，不是云音乐），189 用 189 云图标（512 高清，
/// 不是之前粗糙的蓝底字标），QQ 用 QQMail、微软用 Outlook、新浪用 SINA。
/// Oasisic 没有搜狐、139、雅虎等，返回 nil，走后面的 mini / 网站图标 / 首字母兜底。
enum OasisicIcons {
    static let base = "https://raw.githubusercontent.com/Hawaiine/Oasisic-Icons/main/"
    static let byDomain: [String: String] = [
        "gmail.com": "icons/Google/Gmail/Gmail.png", "googlemail.com": "icons/Google/Gmail/Gmail.png",
        "google.com": "icons/Google/Gmail/Gmail.png",
        "outlook.com": "icons/Microsoft/Outlook/Outlook.png", "hotmail.com": "icons/Microsoft/Outlook/Outlook.png",
        "live.com": "icons/Microsoft/Outlook/Outlook.png", "msn.com": "icons/Microsoft/Outlook/Outlook.png",
        "microsoft.com": "icons/Microsoft/Outlook/Outlook.png", "office.com": "icons/Microsoft/Outlook/Outlook.png",
        "qq.com": "icons/Tencent/QQMail/QQMail.png", "foxmail.com": "icons/Tencent/QQMail/QQMail.png",
        "tencent.com": "icons/Tencent/QQMail/QQMail.png",
        "163.com": "icons/NetEase/NetEaseMail/NetEaseMail.png", "126.com": "icons/NetEase/NetEaseMail/NetEaseMail.png",
        "yeah.net": "icons/NetEase/NetEaseMail/NetEaseMail.png", "netease.com": "icons/NetEase/NetEaseMail/NetEaseMail.png",
        "icloud.com": "icons/Apple/iCloud/iCloud.png", "me.com": "icons/Apple/iCloud/iCloud.png",
        "mac.com": "icons/Apple/iCloud/iCloud.png", "apple.com": "icons/Apple/iCloud/iCloud.png",
        "sina.com": "icons/Social/SINA/SINA.png", "sina.cn": "icons/Social/SINA/SINA.png",
        "sina.com.cn": "icons/Social/SINA/SINA.png", "weibo.com": "icons/Social/Weibo/Weibo.png",
        "weibo.cn": "icons/Social/Weibo/Weibo.png",
        "189.cn": "icons/CloudStorage/189/189.png",
        "aliyun.com": "icons/Alibaba/AlibabaCloud/AlibabaCloud.png", "alibaba.com": "icons/Alibaba/Alibaba/Alibaba.png",
    ]
    static func url(for domain: String) -> String? {
        guard let f = byDomain[domain.lowercased()] else { return nil }
        return base + f
    }
}

/// mini 图标库（Orz-3/mini，公开仓库，仅远程引用、不打包商标图片）：
/// 文件名均已在该仓库 Color/ 目录核对过。找不到对应文件时返回 nil，走后面的
/// BIMI / 网站图标 / Gravatar / 首字母兜底，所以“没有图标库”也不会空白。
enum MiniIcons {
    static let base = "https://raw.githubusercontent.com/Orz-3/mini/master/Color/"
    static let byDomain: [String: String] = [
        "apple.com": "Apple.png", "icloud.com": "Apple.png", "me.com": "Apple.png", "mac.com": "Apple.png",
        "google.com": "Google.png", "gmail.com": "Google.png", "googlemail.com": "Google.png", "youtube.com": "YouTube.png",
        "microsoft.com": "Microsoft.png", "outlook.com": "Microsoft.png", "hotmail.com": "Microsoft.png",
        "live.com": "Microsoft.png", "msn.com": "Microsoft.png", "office.com": "Microsoft.png",
        "qq.com": "QQ.png", "foxmail.com": "QQ.png", "tencent.com": "QQ.png",
        "163.com": "Netease.png", "126.com": "Netease.png", "yeah.net": "Netease.png", "netease.com": "Netease.png",
        "weibo.com": "weibo.png", "weibo.cn": "weibo.png", "sina.com": "weibo.png", "sina.cn": "weibo.png",
        "sina.com.cn": "weibo.png", "sinaimg.cn": "weibo.png",
        "139.com": "10086.png", "github.com": "github.png", "telegram.org": "Telegram.png",
        "twitter.com": "Twitter.png", "x.com": "Twitter.png", "netflix.com": "Netflix.png",
        "spotify.com": "Spotify.png", "steampowered.com": "Steam.png", "disneyplus.com": "DisneyPlus.png",
        "bilibili.com": "bilibili.png", "instagram.com": "Instagram.png", "paypal.com": "Paypal.png",
        "jd.com": "jd.png", "baidu.com": "baidu.png", "alipay.com": "alipay.png",
    ]
    static func url(for domain: String) -> String? {
        guard let f = byDomain[domain.lowercased()] else { return nil }
        return base + f
    }
}

/// 常见发件域名 → 品牌主站（用于取图标）
enum BrandMap {
    static let map: [String: String] = [
        "weibo.com": "weibo.com", "weibo.cn": "weibo.com", "sina.com.cn": "weibo.com", "sinaimg.cn": "weibo.com",
        "tencent.com": "qq.com", "wechat.com": "wechat.com", "weixin.qq.com": "wechat.com", "tenpay.com": "qq.com",
        "alipay.com": "alipay.com", "alibaba.com": "alibaba.com", "alibaba-inc.com": "alibaba.com", "aliyun.com": "aliyun.com",
        "taobao.com": "taobao.com", "tmall.com": "tmall.com", "mail.taobao.com": "taobao.com",
        "jd.com": "jd.com", "jd.hk": "jd.com", "360buy.com": "jd.com",
        "apple.com": "apple.com", "insideapple.apple.com": "apple.com", "email.apple.com": "apple.com",
        "github.com": "github.com", "githubapp.com": "github.com",
        "google.com": "google.com", "accounts.google.com": "google.com", "youtube.com": "youtube.com",
        "microsoft.com": "microsoft.com", "microsoftonline.com": "microsoft.com", "office.com": "microsoft.com", "xbox.com": "xbox.com",
        "bilibili.com": "bilibili.com", "biliapi.com": "bilibili.com",
        "xiaohongshu.com": "xiaohongshu.com", "xhscdn.com": "xiaohongshu.com",
        "meituan.com": "meituan.com", "dianping.com": "dianping.com",
        "douyin.com": "douyin.com", "bytedance.com": "bytedance.com", "toutiao.com": "toutiao.com", "feishu.cn": "feishu.cn",
        "12306.cn": "12306.cn", "ctrip.com": "ctrip.com", "trip.com": "trip.com",
        "icbc.com.cn": "icbc.com.cn", "cmbchina.com": "cmbchina.com", "ccb.com": "ccb.com", "boc.cn": "boc.cn", "abchina.com": "abchina.com",
        "bankcomm.com": "bankcomm.com", "spdb.com.cn": "spdb.com.cn", "cib.com.cn": "cib.com.cn", "citicbank.com": "citicbank.com",
        "pingan.com": "pingan.com", "95559.com.cn": "bankcomm.com",
        "netease.com": "163.com", "service.netease.com": "163.com", "baidu.com": "baidu.com", "zhihu.com": "zhihu.com",
        "pinduoduo.com": "pinduoduo.com", "huawei.com": "huawei.com", "mi.com": "mi.com", "xiaomi.com": "mi.com",
        "amazon.com": "amazon.com", "paypal.com": "paypal.com", "steampowered.com": "steampowered.com", "linkedin.com": "linkedin.com",
        "x.com": "x.com", "twitter.com": "x.com", "facebookmail.com": "facebook.com", "instagram.com": "instagram.com",
    ]

    static func domain(for org: String) -> String? { map[org] }

    /// 品牌族：免费邮箱域名里的官方账号，按“域名族 + 显示名关键词/系统账号”识别，防止 gmail 冒充
    static let families: [(brand: String, domains: Set<String>, keywords: [String])] = [
        ("weibo.com", ["sina.com", "sina.cn", "vip.sina.com", "weibo.com", "weibo.cn"], ["微博", "weibo"]),
        ("sina.com.cn", ["sina.com", "sina.cn", "vip.sina.com"], ["新浪", "sina"]),
        ("qq.com", ["qq.com", "foxmail.com"], ["qq", "腾讯", "tencent"]),
        ("163.com", ["163.com", "126.com", "yeah.net"], ["网易", "netease", "163"]),
        ("icloud.com", ["icloud.com", "me.com"], ["icloud", "apple"]),
        ("google.com", ["gmail.com", "google.com"], ["google", "gmail"]),
        ("microsoft.com", ["outlook.com", "hotmail.com", "live.com"], ["microsoft", "outlook"]),
        ("aliyun.com", ["aliyun.com"], ["阿里云", "aliyun"]),
    ]
    static let systemLocals: Set<String> = ["service", "notice", "notification", "system", "noreply", "no-reply", "admin", "postmaster",
                                            "10000", "10001", "news", "mail", "info", "security", "account", "support"]

    static func officialSender(_ email: String, name: String, org: String) -> String? {
        let local = String(email.split(separator: "@").first ?? "").lowercased()
        let host = String(email.split(separator: "@").last ?? "").lowercased()
        let n = name.lowercased()
        for f in families where f.domains.contains(host) || f.domains.contains(org) {
            if f.keywords.contains(where: { n.contains($0) }) { return f.brand }
        }
        if systemLocals.contains(local) { return families.first { $0.domains.contains(host) || $0.domains.contains(org) }?.brand }
        return nil
    }
}

/// 用离屏 WKWebView 把 BIMI SVG 渲染成位图
@MainActor
final class SVGRenderer: NSObject, WKNavigationDelegate {
    private var cont: CheckedContinuation<UIImage?, Never>?
    private var web: WKWebView?

    static func render(_ svg: Data) async -> UIImage? {
        await SVGRenderer().run(svg)
    }

    private func run(_ svg: Data) async -> UIImage? {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 128, height: 128), configuration: cfg)
        w.isOpaque = false
        w.navigationDelegate = self
        web = w
        if let win = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            w.frame.origin = CGPoint(x: -1000, y: -1000); w.alpha = 0.01; win.addSubview(w)
        }
        let b64 = svg.base64EncodedString()
        let html = "<html><body style='margin:0;background:transparent'><img src='data:image/svg+xml;base64,\(b64)' style='width:128px;height:128px'></body></html>"
        return await withCheckedContinuation { c in
            cont = c
            w.loadHTMLString(html, baseURL: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.finish(nil) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            let cfg = WKSnapshotConfiguration()
            cfg.rect = CGRect(x: 0, y: 0, width: 128, height: 128)
            cfg.afterScreenUpdates = true
            webView.takeSnapshot(with: cfg) { img, _ in self?.finish(img) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }

    private func finish(_ img: UIImage?) {
        cont?.resume(returning: img); cont = nil; web?.removeFromSuperview(); web = nil
    }
}
