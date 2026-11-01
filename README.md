# 📬 FlyMail

<img src="FlyMail.png" alt="FlyMail" width="128">

> 一款干净、快速的 iOS 邮件客户端 —— 多账户、统一收件箱、本地备份恢复，开源 SwiftUI 实现。
>
> 不想被臃肿的邮件 App 绑架？FlyMail 就想做一件事：让你打开就能读邮件，读完就能走。🚀

![iOS](https://img.shields.io/badge/iOS-27.0-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![SwiftUI](https://img.shields.io/badge/SwiftUI-yes-green) ![License](https://img.shields.io/badge/无第三方依赖-lightgrey)

---

## ✨ 它能干嘛

- 📥 **统一收件箱**：首页默认就是全部账户的收件箱，不用一个个账户点过去
- 👥 **多账户随便加**：Gmail、Outlook、QQ、163、126、iCloud、新浪、139、189、搜狐、阿里、Yahoo、联通沃邮箱，还能自定义服务器
- ⚡ **打开就快**：正文只拉文本部分，不拉附件，带大附件的邮件也不用等；上一封、下一封提前预取好
- 🔔 **实时推送**：IMAP IDLE 新邮件到了就同步，后台也会按你设的频率刷新
- 🔍 **搜得到**：本地搜索 + 服务器搜索，同步范围外的旧邮件也能从服务器上找回来
- 🧹 **不怕删错**：删除、归档、移入垃圾邮件都有乐观更新 + 失败回滚，服务器上没了的残留行会自动清掉
- 💾 **本地备份恢复**：设置里一键导出一个 zip，账户、设置、VIP、草稿都在里面，换机传过去导入就能用（密码故意不放进 zip，恢复后重新输一次，安全第一）
- 🤖 **AI 助手内置**：接入 ChatGPT、Claude、Gemini、智谱、通义、Kimi、DeepSeek 等，聊天问答、理解邮件；思考等级对齐各官方档位，长期记忆自动整理，翻译可指定模型
- 🎨 **看着顺眼**：苹果邮件式布局 + 液态玻璃，品牌头像 512×512 高清铺满，不留白边；深浅色模式完整适配

## 🧑‍💻 支持的邮箱

| 服务商 | 收信 | 发信 | 备注 |
|---|---|---|---|
| Gmail | imap.gmail.com:993 | smtp.gmail.com:465 | 推荐 Google 登录，密码登录要用应用专用密码 |
| Microsoft | outlook.office365.com:993 | smtp.office365.com:587 | 推荐微软登录 |
| 腾讯 QQ | imap.qq.com:993 | smtp.qq.com:465 | 填授权码，不是 QQ 密码 |
| 网易 163 / 126 | imap.163.com / imap.126.com:993 | smtp.163.com / smtp.126.com:465 | 填授权码 |
| iCloud | imap.mail.me.com:993 | smtp.mail.me.com:587 | 在 appleid.apple.com 生成 App 专用密码 |
| 新浪 / 搜狐 / 139 / 189 / 阿里 | 各自 imap / smtp:993 / 465 | 同左 | 网页版先开 IMAP/SMTP |
| Yahoo | imap.mail.yahoo.com:993 | smtp.mail.yahoo.com:465 | 要用应用专用密码 |
| 联通沃邮箱 | imap.wo.cn:993 | smtp.wo.cn:465 | ⚠️ 沃官方只公开了 POP/SMTP，IMAP 地址是按常规预填的，登录前先在网页版确认已开启 IMAP；图标用的是中国联通的图标 |
| 自定义 | 自己填 | 自己填 | 啥冷门邮箱都能接 |

## 🔄 版本更新

**版本 1.0 (1)** · 更新时间 2026-11-02

**新特性**

- AI 助手全面升级：历史对话侧栏支持编辑批量管理，左滑即可归档/删除对话，已归档对话单独分区、可随时恢复
- 聊天输入框重做：左侧加号可添加照片和文件，"更多"收进发送键旁的圆形菜单，里面可切换模型、调整思考等级；输入框为空时直接显示当前模型与思考等级
- 各大模型思考等级对齐官方档位（OpenAI、Claude、Gemini、智谱、通义、Kimi、DeepSeek），默认关闭，可手动调整
- AI 长期记忆按对话隔离，自动压缩提炼、全程无感，可在 AI 设置中查看状态或清空
- AI 设置新增"回车键发送"开关（默认关闭）和"默认翻译模型"选择
- 键盘弹出或展开历史侧栏时，底部导航自动让位：输入框顶格贴住键盘，侧栏内容不再被遮挡
- 底部导航与输入框改为白色悬浮胶囊，选中项浅灰高亮，深浅色模式均已适配
- 首页深色模式适配修复：卡片跟随系统深浅色，深色下清晰浮出不再隐形
- 帮助与反馈新增 E-mail 反馈入口，点击直接拉起邮件；界面细节与汉化持续打磨

## 🙏 欢迎来玩

有 bug、有想法、有想加的邮箱服务商，直接在 GitHub 上提 Issue 或者 PR 就行，看到就会回。

作者主页：[@baozhididi](https://github.com/baozhididi) · 项目仓库：[baozhididi/FlyMail](https://github.com/baozhididi/FlyMail)

---

*FlyMail 没有第三方依赖，也没有第三方中转服务器 —— 你的邮件只在你和你的邮箱服务商之间走。* 🔒
