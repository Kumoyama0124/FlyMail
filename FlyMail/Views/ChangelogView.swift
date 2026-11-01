import SwiftUI

/// 品牌图标：走 App 里现成的图标库链路（Oasisic → mini → 网站图标），
/// 和邮件里的品牌头像同一套来源，不用系统图标凑数。
/// mini 库里有 github.png；Discord / 小红书走网站图标兜底，拉不到就显示系统图标兜底。
struct BrandIcon: View {
    let domain: String
    let fallback: String
    let label: String
    @State private var image: UIImage?

    var body: some View {
        // 图标填满整个圆：品牌图直接铺满 30pt 圆，不再是白底圆里套一个小方图
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: fallback).foregroundStyle(.secondary)
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(Circle())
        .accessibilityLabel(label)
        .task {
            // 先走现成图标库链路；拉不到（比如首次超时被负缓存挡了一小时）时，
            // 再直接走 favicon.im 兜底拿品牌站标，不让关于里一直显示系统图标兜底
            if let img = await AvatarService.shared.image(for: "@" + domain) {
                image = img
            } else if let url = URL(string: "https://favicon.im/\(domain)?larger=true"),
                      let (data, _) = try? await URLSession.shared.data(from: url),
                      let img = UIImage(data: data) {
                image = img
            }
        }
    }
}

/// 关于：每一项各占一行 —— GitHub 项目一行、E-mail 反馈一行、Discord 一行，
/// 版本放最后一个（点进去是产品信息页，不是更新日志）。
/// 关于不再直接放在“我的”页上，而是放在“帮助与反馈”二级页里。
struct AboutSectionView: View {
    var body: some View {
        Section {
            Link(destination: URL(string: "https://github.com/baozhididi/FlyMail")!) {
                HStack(spacing: 10) {
                    BrandIcon(domain: "github.com", fallback: "chevron.left.forwardslash.chevron.right", label: "GitHub 项目")
                    Text("FlyMail")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            // E-mail 反馈：信封图标 + E-mail，点开直接拉起系统邮件，收件人已填好
            Link(destination: URL(string: "mailto:baozhididi@sina.com?subject=FlyMail%20反馈")!) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(Color.accentColor.opacity(0.12))
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 30, height: 30)
                    .accessibilityLabel("E-mail")
                    Text("E-mail")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            Link(destination: URL(string: "https://discord.gg/DyqFwJNj")!) {
                HStack(spacing: 10) {
                    BrandIcon(domain: "discord.com", fallback: "message.fill", label: "Discord")
                    Text("Discord")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            // 版本放最后一个，点进去是产品信息页：APP 图标 + 版本和新特性 + 更新时间，不再是长长的更新日志
            NavigationLink {
                ProductInfoView()
            } label: {
                LabeledContent("版本", value: "\(SettingsView.appVersion) (\(SettingsView.appBuild))")
            }
        } header: { Text("关于") }
    }
}

/// 版本产品信息页：只显示这一版的产品信息，不再是长长的更新日志历史。
/// 新特性是当前版的简述，新版发布时改这里，不要往后追加历史。
struct ProductInfoView: View {
    @Environment(\.colorScheme) private var colorScheme

    /// App 自己的真实图标，优先 imageset 里的 1024 原图
    private var appIconImage: UIImage? {
        if let img = UIImage(named: "AppIconDisplay") { return img }
        if let img = UIImage(named: "AppIcon") { return img }
        if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String] {
            for name in files.reversed() {
                if let img = UIImage(named: name) { return img }
            }
        }
        return nil
    }

    // 新特性卡片跟随深浅色，和首页卡片同一套配色逻辑
    private var cardFill: Color {
        colorScheme == .dark ? Color(uiColor: .tertiarySystemBackground) : Color(uiColor: .systemBackground)
    }
    private var cardStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.06)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 1. APP 图标：用 App 自己的图标，不手画
                Group {
                    if let icon = appIconImage {
                        Image(uiImage: icon).resizable().scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: 22).fill(Color(.systemGray5))
                    }
                }
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .padding(.top, 24)
                Text("FlyMail")
                    .font(.title.bold())
                // 2. 版本和新特性
                VStack(spacing: 6) {
                    Text("版本 \(SettingsView.appVersion) (\(SettingsView.appBuild))")
                        .font(.headline)
                    // 3. 更新时间：当前版的发布时间，新版发布时改这个日期
                    Text("更新时间 2026-11-02")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("新特性").font(.headline)
                    ForEach([
                        "邮件详情 AI 菜单升级：一键摘要、提取要点（待办/时间/金额/需要你做的事）、AI 翻译，结果以卡片直接显示在邮件页，可复制，不再跳转聊天窗",
                        "AI 起草回复：读完邮件一键生成回复草稿，直接填进写信页（自动带收件人、主题和原信引用），改完就能发",
                        "写信助手：写信页新增 AI 菜单——润色、改得更正式/简洁、扩写、中英互译、检查错别字；结果先预览，确认后替换正文，替换错了可撤销",
                        "自动回复（实验，默认关闭）：独立的“邮箱 AI 伙伴”人设——自己的名字、性格和专属指令，与系统助手互不影响；收到新邮件自动回复并表明 AI 身份；带防循环与频率限制（跳过验证码/广告/机器人，每发件人每天最多 3 条）；开关在 AI 设置 → 自动回复",
                    ], id: \.self) { f in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•").foregroundStyle(.secondary)
                            Text(f).font(.body)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background { RoundedRectangle(cornerRadius: 16).fill(cardFill).overlay { RoundedRectangle(cornerRadius: 16).stroke(cardStroke, lineWidth: 0.5) } }
                // dock 是悬浮盖在内容上的，底部留出空当，最后一行才能完整滑出来不被遮住
                Color.clear.frame(height: 110)
            }
            .padding(.horizontal, 20)
        }
        .navigationTitle("版本")
    }
}

/// 帮助与反馈：二级页，里面就是关于（GitHub 作者/项目、小红书、Discord、版本在最后）。
struct HelpFeedbackView: View {
    var body: some View {
        List {
            AboutSectionView()
        }
        .navigationTitle("帮助与反馈")
    }
}

/// 版本更新日志：每次更新的内容都记在这里，最新在最前面。
struct ChangelogView: View {
    struct Entry: Identifiable {
        let id = UUID()
        let date: String
        let title: String
        let changes: [String]
    }

    static let entries: [Entry] = [
        Entry(date: "2026-11-01", title: "最新", changes: [
            "App 图标新增深色版：深色主屏幕下用深藏青底 + 白信封，不再被系统压暗；浅色版不变",
            "关于图标填满整个圆，不再是白底圆里套小方图；小红书和 Discord 与 GitHub 行同款",
            "液态玻璃改近白色透明；Dock 选中滑块改白底，滑动看得见",
            "服务里“我的账户”加图标，与“设置”“备份与恢复”对齐",
            "设置、关于、备份等页里的描述性脚注说明全部删掉，只留功能",
            "侧边栏里的“我的”入口删掉，“我的”只在底部 Dock 里有",
            "首页快捷入口可编辑：点“编辑”增删、拖动排序、恢复默认，可选功能包括收件箱、未读、VIP、星标、今天、附件、草稿箱、归档、垃圾邮件、废纸箱、发件箱",
            "联通沃邮箱图标改用中国联通 APP 图标，不再用 10010.com 网站小图标",
            "设置第一组：上面的账户改成 AI，下面还是同步，AI 先留着，暂不提供二级设置",
            "我的页“我的账户”改叫“账户”，设置里的账户入口去掉，账户只在我的页进",
            "我的页按钮统一黑色，账户/设置/备份三行整行点哪里都进",
            "备份与同步二级页的描述加回来，其他页的描述继续不写",
            "液态玻璃改回透明，Dock 和顶部搜索一样白色透明，不发灰",
            "Dock 滑块可手动拖动：手指在横条上滑动时滑块来回跟随，松手切栏目",
            "Dock 改白色透明、无黑色阴影，图标保持黑色，和顶部搜索胶囊一个风格",
            "关于只留我的页，设置页里的关于去掉",
            "收件箱编写按钮改成搜索/筛选同款：白色透明圆、蓝色图标、右边缘和 Dock 对齐",
            "所有液态玻璃统一成搜索/筛选按钮风格：白色透明，不发灰",
            "首页快捷入口图标去掉灰色圆底，改成 iOS 原生图标样式，和右上角搜索图标一样干净",
            "底部导航 4 个也改成原生样式：平时不显示滑块白块，只靠图标颜色区分选中，拖动时滑块才出现跟随手指",
            "首页整体按搜索块重做：个人/统计/快捷卡片改系统玻璃材质，不用实白填充；快捷图标、编辑、Dock 选中改成搜索同款蓝色，未选中灰色",
            "按 Telegram 改：首页卡片和 Dock 改亮白悬浮、轻阴影托起，不再是灰色下陷；Dock 选中 pill 改浅灰常驻，点按/拖动时滑动动画",
            "我的页不再弹 Sheet，改成 Dock 第四个栏目，和首页/邮件/AI 一致；首页/Dock/悬浮按钮全部改回系统液态玻璃 regular，不用白填充/超薄材质；拖动时滑块跟随、松手才切页，内容按方向滑动；CI 改 xcode-27 runner，用真正的 iOS 27 SDK 编译",
            "Dock 按图二 100% 做：亮白悬浮条 + 实心浅灰 pill 填满按钮区，未选中黑色、选中蓝色；Dock 从悬浮覆盖改成底部独立栏，列表最后一行不再被 dock 盖住，我的页“关于”能滑到底看到 Discord",
            "首页同理：Dock 改动是全局的，首页最后一行也不再被 dock 盖住；首页个人/统计/快捷卡片也按图二改成亮白卡片，不再用发灰的 regular 玻璃",
            "我的页重构：关于挪到“帮助与反馈”二级页里，版本挪到关于里最后一个；账户/设置/备份与恢复一个模块，不再加“服务”标题；帮助与反馈独立一个模块区，同样不加模块名；“作为默认签名名片发送”挪到设置里的“写信与角标”",
            "设置里头像模块不再加“头像”标题，只留显示头像、加载发件人头像、清除头像缓存三个功能",
            "设置里“写信与角标”模块同样不再加标题，只留默认写信账户、应用角标、作为默认签名名片发送三个功能",
            "备份与恢复页里本地备份那组不再加“备份与恢复（本地）”小字标题，只留导出、导入两个功能，页标题本身就是备份与恢复",
            "账户页添加账户按钮优化：没账户时按钮放中间；有账户时列表里不再放整行按钮，改成右上角一个加号",
            "账户页新增滑动删除：左滑出删除按钮，点删除先弹居中确认框一次，确认后才删账户及本地缓存，不删服务器邮件；设置里“全部恢复默认”同样改成居中弹窗确认一次再恢复",
            "账户页新增编辑按钮：编辑模式下点行是批量选中，底部删除按钮先弹确认框一次再删选中账户；拖动排序柄可调整同组内顺序，顺序立即保存",
        ]),
        Entry(date: "2026-10-31", title: "Build #24", changes: [
            "应用包名改为 com.gymbull.AIMail：后台任务、URL Scheme、钥匙串、OAuth 一起改",
            "注意：包名一换就是一个新 App，旧包名装的版本数据和已保存密码不会自动带过来，要重新加账户",
        ]),
        Entry(date: "2026-10-31", title: "Build #21", changes: [
            "底部 Dock 按 Muse 式重做：悬浮透明液态玻璃胶囊，选中滑块透明无染色",
            "所有液态玻璃改透明 clear，不再加深色染色；首页卡片也不再用深色 Material",
            "图标尽量圆形：品牌图标白底圆、服务商徽章改圆、首页快捷图标改圆",
            "关于品牌图标加 favicon.im 兜底，拉不到时不再一直显示系统图标",
            "关于每行都写上名字：GitHub 作者写 baozhididi，项目写 FlyMail",
            "小红书和 Discord 与 GitHub 行同款：图标 + 名字 + 右箭头",
            "备份与恢复单独成页：我的页和设置页点进去都是同一页，不再是打开设置页",
            "我的页设置和备份与恢复按钮改黑色，不再是蓝色",
        ]),
        Entry(date: "2026-10-31", title: "Build #20", changes: [
            "我的页首要邮箱可更换：点开在账户间切换，签名名片跟随换",
            "关于排版改回各占一行：版本、GitHub 作者、GitHub 项目、小红书、Discord",
            "小红书和 Discord 先列出来，图标走现成图标库链路，链接待填写",
            "Dock 液态玻璃滑块：选中胶囊在栏目间滑动；玻璃改背景层，不再挡点击",
            "卡顿修复：首页卡片改 Material，悬浮按钮点击区只留圆，详情底部栏玻璃改背景层",
            "邮件导航栏下面的搜索框拿掉，只留工具栏放大镜聚合搜索",
        ]),
        Entry(date: "2026-10-31", title: "Build #19", changes: [
            "底部 dock 改液态玻璃胶囊，栏目变成首页 / 邮件 / AI / 我的",
            "首页总览页：个人卡片、未读统计、快捷邮箱、账户入口；AI 先是个空页",
            "所有收件箱右下角加放大的新建邮件悬浮按钮；三个点菜单移除，添加账户和设置只在我的页",
            "我的页签名名片开关：默认开，新邮件默认签名用昵称 + 签名 + 邮箱",
            "关于改图标链接 + 版本二级更新日志，仓库私有已注明",
        ]),
        Entry(date: "2026-10-31", title: "Build #18", changes: [
            "本地 zip 备份与恢复：设置页一键导出、导入，恢复后重新输密码",
            "设置页关于：版本号 + 作者主页 + 项目仓库；仓库 About 描述已写好",
            "沃邮箱图标改成中国联通的图标，不再显示“沃”字标",
            "README 重写：更生动、带 emoji，准备开源分享",
            "iPhone 底部 dock：邮箱、我的；“我的”个人中心页：可换头像、可改昵称和签名",
        ]),
        Entry(date: "2026-10-31", title: "Build #15", changes: [
            "自动同步大按钮改回普通开关：开是实时推送，关是手动",
            "收件箱幻影未读 1 修复：同步时用服务器 FLAGS 核对已读/星标，角标去重",
            "正文分段只拉文本和小内嵌图，不拉附件，打开更快",
            "新品牌：Yahoo、联通沃邮箱；钥匙串可随 iCloud 备份恢复",
        ]),
        Entry(date: "2026-10-31", title: "Build #14", changes: [
            "侧边栏收件箱蓝点 + 未读数；图标换 Oasisic 512×512 优先",
            "详情页上一封/下一封只留一层液态玻璃；上下封预取",
            "部署目标改为 iOS 27（构建仍用 iOS 26.5 SDK，见关于页说明）",
        ]),
        Entry(date: "2026-10-31", title: "Build #13", changes: [
            "头像和品牌图标拉伸铺满，不留白边；账户页只按平台分组",
            "详情页底部胶囊和写信圆钮用液态玻璃，删阴影",
        ]),
        Entry(date: "2026-10-31", title: "Build #12", changes: [
            "修复编译问题（详情页缺 SwiftData 导入）；第一个可用包",
            "首页默认收件箱、删除残留清理、品牌图标快速通道",
        ]),
    ]

    var body: some View {
        List {
            ForEach(Self.entries) { e in
                Section {
                    ForEach(e.changes, id: \.self) { c in
                        Text(c).font(.body)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title).font(.headline)
                        Text(e.date).font(.caption).foregroundStyle(.secondary)
                    }
                    .textCase(nil)
                }
            }
        }
        .navigationTitle("版本更新")
    }
}
