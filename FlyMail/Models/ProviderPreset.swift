import Foundation

struct ProviderPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let imapHost: String
    let imapPort: Int
    let smtpHost: String
    let smtpPort: Int
    let oauth: AuthKind?
    let passwordHint: String

    /// 用于卡片图标：品牌域名、字标、主色（自绘，不打包任何商标图片）
    var iconDomain: String { Self.style[id]?.0 ?? "" }
    var monogram: String { Self.style[id]?.1 ?? "@" }
    var tint: (Double, Double, Double) { Self.style[id]?.2 ?? (0.45, 0.45, 0.5) }
    static let style: [String: (String, String, (Double, Double, Double))] = [
        "gmail": ("gmail.com", "G", (0.86, 0.27, 0.22)), "outlook": ("outlook.com", "M", (0.0, 0.47, 0.84)),
        "icloud": ("icloud.com", "", (0.25, 0.6, 0.95)), "qq": ("qq.com", "Q", (0.12, 0.6, 0.95)),
        "aliyun": ("aliyun.com", "阿", (1.0, 0.42, 0.0)), "163": ("163.com", "163", (0.85, 0.15, 0.15)),
        "126": ("126.com", "126", (0.2, 0.62, 0.35)), "sohu": ("sohu.com", "搜", (0.95, 0.75, 0.1)),
        "sina": ("sina.com.cn", "浪", (0.9, 0.2, 0.15)), "139": ("139.com", "139", (0.0, 0.55, 0.85)),
        "189": ("189.cn", "189", (0.0, 0.45, 0.8)),
        // 沃邮箱：图标走中国联通 APP 图标（AvatarService 里先拉 App Store 官方图），不再用“沃”字标；
        // “沃”只在离线、图标实在拉不到时才作为兜底字标出现
        "yahoo": ("yahoo.com", "Y", (0.36, 0.14, 0.62)), "wo": ("10010.com", "沃", (0.85, 0.1, 0.2)),
        "custom": ("", "", (0.45, 0.45, 0.5)),
    ]

    static let all: [ProviderPreset] = [
        .init(id: "gmail", name: "Gmail", imapHost: "imap.gmail.com", imapPort: 993, smtpHost: "smtp.gmail.com", smtpPort: 465, oauth: .oauthGoogle, passwordHint: "可用 Google 登录，或开启两步验证后生成“应用专用密码”"),
        .init(id: "outlook", name: "Microsoft", imapHost: "outlook.office365.com", imapPort: 993, smtpHost: "smtp.office365.com", smtpPort: 587, oauth: .oauthMicrosoft, passwordHint: "推荐使用微软登录（基本认证已逐步停用）"),
        .init(id: "qq", name: "腾讯 QQ", imapHost: "imap.qq.com", imapPort: 993, smtpHost: "smtp.qq.com", smtpPort: 465, oauth: nil, passwordHint: "填写 QQ 邮箱“授权码”，不是 QQ 密码"),
        .init(id: "163", name: "网易 163", imapHost: "imap.163.com", imapPort: 993, smtpHost: "smtp.163.com", smtpPort: 465, oauth: nil, passwordHint: "填写网易邮箱“授权码”"),
        .init(id: "126", name: "网易 126", imapHost: "imap.126.com", imapPort: 993, smtpHost: "smtp.126.com", smtpPort: 465, oauth: nil, passwordHint: "填写网易邮箱“授权码”"),
        .init(id: "icloud", name: "iCloud", imapHost: "imap.mail.me.com", imapPort: 993, smtpHost: "smtp.mail.me.com", smtpPort: 587, oauth: nil, passwordHint: "在 appleid.apple.com 生成 App 专用密码"),
        .init(id: "sina", name: "新浪", imapHost: "imap.sina.com", imapPort: 993, smtpHost: "smtp.sina.com", smtpPort: 465, oauth: nil, passwordHint: "需在网页版开启 IMAP/SMTP，填写授权码"),
        .init(id: "139", name: "139 邮箱", imapHost: "imap.139.com", imapPort: 993, smtpHost: "smtp.139.com", smtpPort: 465, oauth: nil, passwordHint: "需开启 IMAP/SMTP，填写授权码"),
        .init(id: "189", name: "189 邮箱", imapHost: "imap.189.cn", imapPort: 993, smtpHost: "smtp.189.cn", smtpPort: 465, oauth: nil, passwordHint: "需开启 IMAP/SMTP，填写授权码"),
        .init(id: "sohu", name: "搜狐", imapHost: "imap.sohu.com", imapPort: 993, smtpHost: "smtp.sohu.com", smtpPort: 465, oauth: nil, passwordHint: "需开启 IMAP/SMTP，填写独立密码"),
        .init(id: "aliyun", name: "阿里邮箱", imapHost: "imap.aliyun.com", imapPort: 993, smtpHost: "smtp.aliyun.com", smtpPort: 465, oauth: nil, passwordHint: "企业版为 imap.qiye.aliyun.com，可在自定义中修改"),
        .init(id: "yahoo", name: "Yahoo 邮箱", imapHost: "imap.mail.yahoo.com", imapPort: 993, smtpHost: "smtp.mail.yahoo.com", smtpPort: 465, oauth: nil, passwordHint: "需在 Yahoo 账户安全里生成“应用专用密码”，普通密码登录会被拒绝"),
        .init(id: "wo", name: "联通沃邮箱", imapHost: "imap.wo.cn", imapPort: 993, smtpHost: "smtp.wo.cn", smtpPort: 465, oauth: nil, passwordHint: "沃邮箱官方只公开了 POP/SMTP，IMAP 按常规 imap.wo.cn 预填；若登录失败，先在网页版确认已开启 IMAP，或在账户编辑里改服务器地址"),
        .init(id: "custom", name: "自定义", imapHost: "", imapPort: 993, smtpHost: "", smtpPort: 465, oauth: nil, passwordHint: "填写服务器地址、端口和密码"),
    ]

    static func preset(_ id: String) -> ProviderPreset { all.first { $0.id == id } ?? all.last! }

    static func guess(email: String) -> ProviderPreset {
        let d = email.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        switch d {
        case "gmail.com", "googlemail.com": return preset("gmail")
        case "outlook.com", "hotmail.com", "live.com", "msn.com": return preset("outlook")
        case "qq.com", "foxmail.com", "vip.qq.com": return preset("qq")
        case "163.com": return preset("163")
        case "126.com": return preset("126")
        case "icloud.com", "me.com", "mac.com": return preset("icloud")
        case "sina.com", "sina.cn": return preset("sina")
        case "139.com": return preset("139")
        case "189.cn": return preset("189")
        case "sohu.com": return preset("sohu")
        case "aliyun.com": return preset("aliyun")
        case "yahoo.com", "yahoo.com.cn", "ymail.com": return preset("yahoo")
        case "wo.cn", "wo.com.cn": return preset("wo")
        default: return preset("custom")
        }
    }
}
