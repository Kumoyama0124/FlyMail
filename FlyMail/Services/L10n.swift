import Foundation

/// 轻量运行时多语言：切语言立即生效（配合 AppState.uiLanguageRev 强制重建界面），无需重启。
/// key = 简体中文字符串本身（源语言），查表返回目标语言；没有对应词条时回退原文。
/// 首批适配：简体中文（源）、繁体中文、English、日本語。未覆盖的页面后续版本继续补。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en
    case ja

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .ja: return "日本語"
        }
    }
}

enum L10n {
    static let key = "app.language"

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    /// 实际生效的语言代码
    static var resolved: String {
        switch current {
        case .zhHans: return "zh-Hans"
        case .zhHant: return "zh-Hant"
        case .en: return "en"
        case .ja: return "ja"
        case .system:
            for l in Locale.preferredLanguages {
                if l.hasPrefix("zh") {
                    return (l.contains("Hant") || l.contains("HK") || l.contains("TW") || l.contains("MO")) ? "zh-Hant" : "zh-Hans"
                }
                if l.hasPrefix("ja") { return "ja" }
                if l.hasPrefix("en") { return "en" }
            }
            return "zh-Hans"
        }
    }

    static func t(_ zh: String) -> String {
        let target = resolved
        guard target != "zh-Hans" else { return zh }
        let table: [String: String]
        switch target {
        case "zh-Hant": table = L10nTables.zhHant
        case "en": table = L10nTables.en
        case "ja": table = L10nTables.ja
        default: return zh
        }
        return table[zh] ?? zh
    }

    /// 带参数的翻译：词条用 %lld / %@ 占位
    static func t(_ zh: String, _ args: CVarArg...) -> String {
        String(format: t(zh), locale: Locale.current, arguments: args)
    }
}

enum L10nTables {
    static let zhHant: [String: String] = [
        "首页": "首頁", "邮件": "郵件", "AI": "AI", "我的": "我的",
        "设置": "設定", "同步": "同步", "自定义": "自訂",
        "编辑侧边栏": "編輯側邊欄", "外观与列表": "外觀與列表", "滑动操作": "滑動操作",
        "按主题合并会话": "按主題合併會話", "默认邮箱": "預設郵箱", "第一个账户": "第一個帳戶",
        "应用角标": "應用程式角標", "仅收件箱未读": "僅收件匣未讀", "所有未读": "所有未讀",
        "VIP 未读": "VIP 未讀", "不显示": "不顯示", "资料卡签名": "資料卡簽名",
        "备份与恢复": "備份與還原", "显示头像": "顯示頭像", "加载发件人头像": "載入寄件者頭像",
        "清除头像缓存": "清除頭像快取", "VIP 发件人": "VIP 寄件者", "垃圾邮件": "垃圾郵件",
        "还原设置": "還原設定", "语言": "語言", "跟随系统": "跟隨系統", "完成": "完成",
        "切换后界面立即生效，默认跟随系统语言。": "切換後介面立即生效，預設跟隨系統語言。",
        "对话": "對話", "编辑": "編輯", "新建对话": "新對話", "搜索历史对话": "搜尋歷史對話",
        "最近对话": "最近對話", "搜索结果": "搜尋結果", "全选": "全選", "全不选": "全不選",
        "已选 %lld": "已選 %lld", "归档所选": "封存所選", "删除所选": "刪除所選",
        "删除": "刪除", "归档": "封存", "恢复": "恢復", "已归档 %lld": "已封存 %lld",
        "对话和记忆仅保存在本机": "對話和記憶僅保存在本機",
        "开始与 AI 对话": "開始與 AI 對話", "开始与 %@ 对话": "開始與 %@ 對話",
        "AI 尚未配置": "AI 尚未設定",
        "可以直接提问，也可以添加图片或文件。邮件内容不会自动加入对话。": "可以直接提問，也可以添加圖片或檔案。郵件內容不會自動加入對話。",
        "请先点击右上角齿轮，在 AI 设置中添加模型并保存 API Key。": "請先點擊右上角齒輪，在 AI 設置中添加模型並保存 API Key。",
        "打开 AI 设置": "打開 AI 設置", "发送消息…": "傳送訊息…",
        "思考已关闭": "思考已關閉", "思考 · %@": "思考 · %@",
        "选择照片": "選擇照片", "添加文件": "添加檔案", "添加图片或文件": "添加圖片或檔案",
        "发送": "傳送", "AI 处理中…": "AI 處理中…", "AI 正在思考…": "AI 正在思考…",
        "AI 设置": "AI 設置", "对话历史": "對話歷史", "在 AI 对话中深入": "在 AI 對話中深入",
        "AI 请求失败": "AI 請求失敗", "好": "好", "复制": "複製", "已复制": "已複製",
        "关闭": "關閉", "取消": "取消",
        "AI 摘要": "AI 摘要", "提取要点": "提取要點", "AI 翻译为中文": "AI 翻譯為中文",
        "AI 起草回复": "AI 起草回覆",
        "模型配置": "模型配置", "添加模型": "添加模型", "主模型与回退": "主模型與後備",
        "首选模型": "首選模型", "AI 个性化": "AI 個性化", "助手资料卡": "助手資料卡",
        "聊天体验": "聊天體驗", "回车键发送": "回車鍵發送", "顯示頭像": "顯示頭像",
        "翻译": "翻譯", "預設翻譯模型": "預設翻譯模型", "AI 记忆": "AI 記憶",
        "清空长期记忆": "清空長期記憶", "自动回复": "自動回覆",
        "GitHub 项目": "GitHub 專案", "版本": "版本",
        "助手名称": "助手名稱", "助手头像": "助手頭像", "性别": "性別", "年龄": "年齡",
        "身高": "身高", "体重": "體重", "星座": "星座", "未设置": "未設置", "岁": "歲",
        "通用": "一般", "还原设置？": "還原設定？", "新特性": "新特性",
        "将侧边栏、外观、滑动等自定义还原为默认，不影响账户和 VIP。": "將側邊欄、外觀、滑動等自訂還原為預設，不影響帳戶和 VIP。",
    ]

    static let en: [String: String] = [
        "首页": "Home", "邮件": "Mail", "AI": "AI", "我的": "Me",
        "设置": "Settings", "同步": "Sync", "自定义": "Customize",
        "编辑侧边栏": "Edit Sidebar", "外观与列表": "Appearance & List", "滑动操作": "Swipe Actions",
        "按主题合并会话": "Group by Subject", "默认邮箱": "Default Account", "第一个账户": "First Account",
        "应用角标": "App Badge", "仅收件箱未读": "Inbox Unread", "所有未读": "All Unread",
        "VIP 未读": "VIP Unread", "不显示": "None", "资料卡签名": "Signature Card",
        "备份与恢复": "Backup & Restore", "显示头像": "Show Avatars", "加载发件人头像": "Load Sender Avatars",
        "清除头像缓存": "Clear Avatar Cache", "VIP 发件人": "VIP Senders", "垃圾邮件": "Spam",
        "还原设置": "Reset Settings", "语言": "Language", "跟随系统": "Follow System", "完成": "Done",
        "切换后界面立即生效，默认跟随系统语言。": "Changes apply immediately. Defaults to your system language.",
        "对话": "Chats", "编辑": "Edit", "新建对话": "New Chat", "搜索历史对话": "Search chats",
        "最近对话": "Recent", "搜索结果": "Results", "全选": "Select All", "全不选": "Deselect All",
        "已选 %lld": "%lld selected", "归档所选": "Archive Selected", "删除所选": "Delete Selected",
        "删除": "Delete", "归档": "Archive", "恢复": "Restore", "已归档 %lld": "Archived %lld",
        "对话和记忆仅保存在本机": "Chats and memory stay on this device",
        "开始与 AI 对话": "Start Chatting", "开始与 %@ 对话": "Chat with %@",
        "AI 尚未配置": "AI Not Set Up",
        "可以直接提问，也可以添加图片或文件。邮件内容不会自动加入对话。": "Ask anything, or add photos and files. Email content is never added automatically.",
        "请先点击右上角齿轮，在 AI 设置中添加模型并保存 API Key。": "Tap the gear in the top right to add a model in AI Settings and save its API key.",
        "打开 AI 设置": "Open AI Settings", "发送消息…": "Message…",
        "思考已关闭": "thinking off", "思考 · %@": "thinking · %@",
        "选择照片": "Choose Photos", "添加文件": "Add File", "添加图片或文件": "Add Photo or File",
        "发送": "Send", "AI 处理中…": "Working…", "AI 正在思考…": "Thinking…",
        "AI 设置": "AI Settings", "对话历史": "History", "在 AI 对话中深入": "Continue in Chat",
        "AI 请求失败": "AI Request Failed", "好": "OK", "复制": "Copy", "已复制": "Copied",
        "关闭": "Close", "取消": "Cancel",
        "AI 摘要": "Summarize", "提取要点": "Key Points", "AI 翻译为中文": "Translate to Chinese",
        "AI 起草回复": "Draft Reply",
        "模型配置": "Models", "添加模型": "Add Model", "主模型与回退": "Primary & Fallback",
        "首选模型": "Primary Model", "AI 个性化": "Personalization", "助手资料卡": "Assistant Profile",
        "聊天体验": "Chat Experience", "回车键发送": "Enter to Send", "顯示頭像": "Show Avatars",
        "翻译": "Translation", "預設翻譯模型": "Translation Model", "AI 记忆": "AI Memory",
        "清空长期记忆": "Clear Long-term Memory", "自动回复": "Auto Reply",
        "GitHub 项目": "GitHub Project", "版本": "Version",
        "助手名称": "Assistant Name", "助手头像": "Assistant Avatar", "性别": "Gender", "年龄": "Age",
        "身高": "Height", "体重": "Weight", "星座": "Zodiac", "未设置": "Not set", "岁": "yrs",
        "通用": "General", "还原设置？": "Reset Settings?", "新特性": "What's New",
        "将侧边栏、外观、滑动等自定义还原为默认，不影响账户和 VIP。": "Restores sidebar, appearance and swipe customizations to defaults. Accounts and VIP are not affected.",
    ]

    static let ja: [String: String] = [
        "首页": "ホーム", "邮件": "メール", "AI": "AI", "我的": "マイ",
        "设置": "設定", "同步": "同期", "自定义": "カスタマイズ",
        "编辑侧边栏": "サイドバーを編集", "外观与列表": "外観とリスト", "滑动操作": "スワイプ操作",
        "按主题合并会话": "スレッドをまとめる", "默认邮箱": "既定のアカウント", "第一个账户": "最初のアカウント",
        "应用角标": "アプリバッジ", "仅收件箱未读": "受信箱の未読", "所有未读": "すべての未読",
        "VIP 未读": "VIP 未読", "不显示": "表示しない", "资料卡签名": "署名カード",
        "备份与恢复": "バックアップと復元", "显示头像": "アバターを表示", "加载发件人头像": "差出人アバターを読み込む",
        "清除头像缓存": "アバターキャッシュを削除", "VIP 发件人": "VIP 差出人", "垃圾邮件": "スパム",
        "还原设置": "設定をリセット", "语言": "言語", "跟随系统": "システムに従う", "完成": "完了",
        "切换后界面立即生效，默认跟随系统语言。": "変更はすぐに反映されます。既定はシステム言語です。",
        "对话": "チャット", "编辑": "編集", "新建对话": "新規チャット", "搜索历史对话": "履歴を検索",
        "最近对话": "最近のチャット", "搜索结果": "検索結果", "全选": "すべて選択", "全不选": "選択を解除",
        "已选 %lld": "%lld 件選択", "归档所选": "選択をアーカイブ", "删除所选": "選択を削除",
        "删除": "削除", "归档": "アーカイブ", "恢复": "復元", "已归档 %lld": "アーカイブ済み %lld",
        "对话和记忆仅保存在本机": "チャットとメモリーは端末内にのみ保存されます",
        "开始与 AI 对话": "チャットを始める", "开始与 %@ 对话": "%@ とチャット",
        "AI 尚未配置": "AI 未設定",
        "可以直接提问，也可以添加图片或文件。邮件内容不会自动加入对话。": "自由に質問したり、写真やファイルを追加したりできます。メールの内容は自動には追加されません。",
        "请先点击右上角齿轮，在 AI 设置中添加模型并保存 API Key。": "右上の歯車から AI 設置を開き、モデルと API キーを追加してください。",
        "打开 AI 设置": "AI 設置を開く", "发送消息…": "メッセージ…",
        "思考已关闭": "思考オフ", "思考 · %@": "思考 · %@",
        "选择照片": "写真を選択", "添加文件": "ファイルを追加", "添加图片或文件": "写真やファイルを追加",
        "发送": "送信", "AI 处理中…": "処理中…", "AI 正在思考…": "考えています…",
        "AI 设置": "AI 設置", "对话历史": "履歴", "在 AI 对话中深入": "AI チャットで続ける",
        "AI 请求失败": "AI リクエスト失敗", "好": "OK", "复制": "コピー", "已复制": "コピーしました",
        "关闭": "閉じる", "取消": "キャンセル",
        "AI 摘要": "要約", "提取要点": "要点抽出", "AI 翻译为中文": "中国語に翻訳",
        "AI 起草回复": "返信を下書き",
        "模型配置": "モデル設定", "添加模型": "モデルを追加", "主模型与回退": "メインとフォールバック",
        "首选模型": "メインモデル", "AI 个性化": "パーソナライズ", "助手资料卡": "アシスタントプロフィール",
        "聊天体验": "チャット体験", "回车键发送": "Enter で送信", "顯示頭像": "アバターを表示",
        "翻译": "翻訳", "預設翻譯模型": "翻訳モデル", "AI 记忆": "AI メモリー",
        "清空长期记忆": "長期メモリーを消去", "自动回复": "自動返信",
        "GitHub 项目": "GitHub プロジェクト", "版本": "バージョン",
        "助手名称": "アシスタント名", "助手头像": "アシスタントアバター", "性别": "性別", "年龄": "年齢",
        "身高": "身長", "体重": "体重", "星座": "星座", "未设置": "未設定", "岁": "歳",
        "通用": "一般", "还原设置？": "設定をリセットしますか？", "新特性": "新機能",
        "将侧边栏、外观、滑动等自定义还原为默认，不影响账户和 VIP。": "サイドバー・外観・スワイプなどのカスタマイズを既定に戻します。アカウントと VIP には影響しません。",
    ]
}
