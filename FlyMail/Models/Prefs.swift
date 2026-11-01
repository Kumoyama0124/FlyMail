import SwiftUI

/// 所有可自定义项的键与默认值（UserDefaults / @AppStorage）
enum Prefs {
    static let smartOrder = "prefs.smartOrder"
    static let smartHidden = "prefs.smartHidden"
    static let homeShortcuts = "prefs.homeShortcuts"
    static let defaultHomeShortcuts = "unified,unread,vip,flagged,today,drafts"
    static let density = "prefs.density"            // 0 紧凑 1 标准 2 宽松
    static let previewLines = "prefs.previewLines"  // 0...3
    static let showAvatars = "prefs.showAvatars"
    static let remoteAvatars = "prefs.remoteAvatars"
    static let leading1 = "prefs.swipe.leading1", leading2 = "prefs.swipe.leading2"
    static let trailing1 = "prefs.swipe.trailing1", trailing2 = "prefs.swipe.trailing2"
    static let defaultAccount = "prefs.defaultAccount"
    static let accent = "prefs.accent"
    static let badgeSource = "prefs.badgeSource"    // inbox / all / vip / none
    static let grouping = "prefs.grouping"
    static let vipList = "prefs.vipList"
    /// 总收件箱里不展示的邮箱：逗号分隔的账户 UUID，只影响聚合显示，不删账户不删邮件
    static let unifiedHiddenAccounts = "prefs.unifiedHiddenAccounts"
    // 个人中心：头像存文件，昵称/签名存 UserDefaults
    static let myNickname = "profile.nickname"
    static let mySignature = "profile.signature"
    /// 个人中心里选中的首要邮箱：可在账户间更换；空表示跟第一个账户
    static let myEmail = "profile.email"
    /// 个人信息是否默认作为签名名片发送（开：新邮件默认签名用“我的”页的昵称+签名+邮箱）
    static let mySignatureCard = "profile.signatureCard"
    // 同步
    static let syncRangeDays = "prefs.sync.rangeDays"     // 0 = 全部
    static let syncInterval = "prefs.sync.interval"       // 0 = 实时推送(IDLE)，>0 分钟，-1 手动
    static let autoBody = "prefs.sync.autoBody"           // all / wifi / off
    static let autoAttach = "prefs.sync.autoAttach"       // off / 1 / 5 / 20 / wifi

    static let rangeOptions: [(Int, String)] = [(3, "最近 3 天"), (7, "最近 1 周"), (14, "最近 2 周"), (30, "最近 1 个月"),
                                               (90, "最近 3 个月"), (180, "最近 6 个月"), (365, "最近 1 年"), (0, "全部")]
    static let intervalOptions: [(Int, String)] = [(0, "实时推送"), (1, "每 1 分钟"), (5, "每 5 分钟"), (15, "每 15 分钟"),
                                                  (30, "每 30 分钟"), (60, "每 60 分钟"), (-1, "手动")]

    static var rangeDays: Int { UserDefaults.standard.integer(forKey: syncRangeDays) }
    /// 自动预取时允许的单封邮件最大字节数（含附件）；0 表示不预取
    static func prefetchLimit(onWiFi: Bool) -> Int {
        let d = UserDefaults.standard
        let body = d.string(forKey: autoBody) ?? "all"
        if body == "off" || (body == "wifi" && !onWiFi) { return 0 }
        let textOnly = 512 * 1024   // 没有附件或附件很小的正文
        switch d.string(forKey: autoAttach) ?? "5" {
        case "1": return 1 << 20
        case "5": return 5 << 20
        case "20": return 20 << 20
        case "wifi": return onWiFi ? 50 << 20 : textOnly
        default: return textOnly
        }
    }

    static let allSmart = ["unified", "vip", "unread", "flagged", "today", "attachments", "drafts", "archive", "junk", "trash", "outbox"]
    static let defaultSmartOrder = allSmart.joined(separator: ",")

    static let smartNames = ["unified": "收件箱", "vip": "VIP", "unread": "未读", "flagged": "星标", "today": "今天",
                             "attachments": "附件", "drafts": "草稿箱", "archive": "归档", "junk": "垃圾邮件", "trash": "废纸箱", "outbox": "发件箱 / 定时"]
    static let smartIcons = ["unified": "tray.2", "vip": "star.circle", "unread": "envelope.badge", "flagged": "star", "today": "calendar",
                             "attachments": "paperclip", "drafts": "doc", "archive": "archivebox", "junk": "xmark.bin", "trash": "trash", "outbox": "clock.arrow.circlepath"]

    static let swipeActions = ["none", "read", "flag", "archive", "delete", "junk", "move", "vip"]
    static let swipeNames = ["none": "无", "read": "已读/未读", "flag": "星标", "archive": "归档", "delete": "删除", "junk": "垃圾邮件", "move": "移动", "vip": "VIP"]

    static let palette: [Color] = [.blue, .indigo, .purple, .pink, .red, .orange, .yellow, .green, .mint, .teal, .cyan, .brown, .gray]
    static let paletteNames = ["蓝", "靛", "紫", "粉", "红", "橙", "黄", "绿", "薄荷", "青绿", "青", "棕", "灰"]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            smartOrder: defaultSmartOrder, smartHidden: "", density: 1, previewLines: 2, showAvatars: true, remoteAvatars: true,
            leading1: "read", leading2: "flag", trailing1: "delete", trailing2: "archive", defaultAccount: "", accent: 0,
            badgeSource: "inbox", grouping: false,
            syncRangeDays: 30, syncInterval: 0, autoBody: "all", autoAttach: "5",
        ])
    }

    static func resetAll() {
        for k in [smartOrder, smartHidden, homeShortcuts, density, previewLines, showAvatars, remoteAvatars, leading1, leading2, trailing1, trailing2,
                  defaultAccount, accent, badgeSource, grouping, syncRangeDays, syncInterval, autoBody, autoAttach, "sidebar.expanded", "sidebar.collapsed", "sidebar.moreExpanded"] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    /// 合并新加入的智能邮箱，保证顺序列表完整
    /// 首页快捷入口：已存的值原样用（删光就是删光，不自动补回）；只过滤掉非法键
    static func homeShortcutKeys(_ raw: String) -> [String] {
        raw.split(separator: ",").map(String.init).filter { allSmart.contains($0) }
    }

    static func orderedSmart(_ raw: String) -> [String] {
        var list = raw.split(separator: ",").map(String.init).filter { allSmart.contains($0) }
        for s in allSmart where !list.contains(s) { list.append(s) }
        return list
    }
}

enum VIPStore {
    /// 逗号分隔存储，便于 @AppStorage 触发界面刷新
    static var list: [String] { (UserDefaults.standard.string(forKey: Prefs.vipList) ?? "").split(separator: ",").map(String.init) }
    private static func save(_ l: [String]) { UserDefaults.standard.set(l.joined(separator: ","), forKey: Prefs.vipList) }
    static func contains(_ from: String) -> Bool {
        guard let a = MIMEParser.addresses(from).first?.lowercased() else { return false }
        return list.contains(a)
    }
    static func toggle(_ from: String) {
        guard let a = MIMEParser.addresses(from).first?.lowercased() else { return }
        var l = list
        if l.contains(a) { l.removeAll { $0 == a } } else { l.append(a) }
        save(l)
    }
    static func remove(_ a: String) { save(list.filter { $0 != a }) }
}
