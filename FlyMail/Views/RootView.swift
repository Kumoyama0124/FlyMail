import SwiftUI
import SwiftData
import UserNotifications

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query private var accounts: [Account]
    @AppStorage(Prefs.accent) private var accent = 0
    @State private var columns: NavigationSplitViewVisibility = .all
    /// 内容滑动方向：新栏在旧栏右边就从右滑入，反之从左滑入
    @State private var slideEdge: Edge = .trailing
    /// iPhone 启动直接进入“收件箱”列表
    @State private var compactColumn: NavigationSplitViewColumn = .content
    @AppStorage(Prefs.syncInterval) private var syncInterval = 0
    private let outboxTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        @Bindable var app = app
        Group {
            Group {
                if sizeClass == .compact {
                    switch app.dockTab {
                    case .home: HomeView().transition(tabTransition)
                    case .mail: mailSplitView.transition(tabTransition)
                    case .ai: AIChatView().transition(tabTransition)
                    case .my: MyView().transition(tabTransition)
                    }
                } else {
                    mailSplitView
                }
            }
            // 内容只平移、不缩放不淡入（重列表上缩放 + 淡入要整页重光栅，最容易掉帧）；
            // 弹簧和 DockBar 松手时的 settle 同一个节奏，滑块落位和页面滑入同时到位。
            .animation(.spring(response: 0.38, dampingFraction: 0.82), value: app.dockTab)
            .tint(Prefs.palette[accent % Prefs.palette.count])
        }
        // dock 必须是真悬浮：用 overlay 贴在内容上面，内容铺满整个屏幕到底，dock 下面看到的就是页面本身的底色
        // （侧边栏/我的页是浅灰，首页/邮件列表是白），不再是一整块白色矩形。dock 再往下挪：overlay 底部只留 2pt，
        // 贴着小横条上面，比之前 8pt 更贴底。
        // dock 单独放在 DockBar 里，body 里只留一行引用，也避免编译器类型推断超时。
        .overlay(alignment: .bottom) {
            // 底部 dock 栏：只在 iPhone（紧凑宽度）显示，iPad 有侧边栏就不需要，
            // 邮件详情页有自己的底部栏，dock 让位给它。
            if sizeClass == .compact, showDock {
                dockOverlay
            }
        }
        .background { BadgeUpdater() }
        .sheet(isPresented: $app.showingAccountSetup) { AccountSetupView() }
        .sheet(isPresented: $app.showingSettings) { SettingsView() }
        .sheet(isPresented: $app.showingSearch) { GlobalSearchView() }
        .alert("没有归档文件夹", isPresented: Binding(get: { app.archiveNeedsFolder != nil }, set: { if !$0 { app.archiveNeedsFolder = nil } })) {
            Button("创建并归档") {
                if let m = app.archiveNeedsFolder { MessageActions.createArchiveAndArchive(m, app: app, context: context) }
                app.archiveNeedsFolder = nil
            }
            Button("取消", role: .cancel) { app.archiveNeedsFolder = nil }
        } message: { Text("该账户在服务器上没有归档文件夹，要创建一个吗？") }
        .sheet(item: $app.composeDraft) { d in ComposeView(draft: d) }
        .alert("出错了", isPresented: Binding(get: { app.lastError != nil }, set: { if !$0 { app.lastError = nil } })) {
            Button("好") {}
        } message: { Text(app.lastError ?? "") }
        .onAppear {
            if accounts.isEmpty { app.showingAccountSetup = true }
            if app.selectedMailbox == nil { app.selectedMailbox = .unified }
            IdleManager.shared.start(container: context.container)
        }
        .onChange(of: syncInterval) { _, _ in IdleManager.shared.restart(container: context.container) }
        .onChange(of: accounts.count) { _, _ in IdleManager.shared.start(container: context.container) }
        .onReceive(outboxTimer) { _ in
            Task { await OutboxService(modelContainer: context.container).flushDue() }
        }
        .onChange(of: phase) { _, p in
            if p == .active {
                Task { await MailSyncService(modelContainer: context.container).syncAll() }
                IdleManager.shared.start(container: context.container)
            } else if p == .background {
                IdleManager.shared.stop()
            }
        }
    }

    /// dock：独立成 DockBar，拖动状态不再放在 RootView 里（见 DockBar.swift 顶部说明）。
    /// 注意 tint：overlay 在 .tint 所在的 Group 外面，所以这里要单独再设一次，
    /// 否则 dock 的选中色永远是系统默认蓝，不跟“主题色”设置走。
    private var dockOverlay: some View {
        DockBar(onSelect: selectTab)
            .tint(Prefs.palette[accent % Prefs.palette.count])
            .padding(.horizontal, 16)
            .padding(.bottom, 2)
    }

    /// 邮件栏目里打开了详情页时不显示 dock，详情页自己的底部栏在底下
    private var showDock: Bool {
        !(app.dockTab == .mail && app.selectedMessage != nil)
    }

    private var mailSplitView: some View {
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } content: {
            MessageListContainer(mailbox: app.selectedMailbox)
                .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            if let id = app.selectedMessage, let m = context.model(for: id) as? MailMessage {
                MessageDetailView(message: m)
            } else {
                ContentUnavailableView("未选择邮件", systemImage: "envelope.open")
            }
        }
    }

    private var tabTransition: AnyTransition {
        // 内容只平移，不缩放不淡入：缩放 + 淡入要重光栅整页列表，邮件这种重列表最容易掉帧，
        // 看着就是“点按完整、拖动不顺”。纯平移 + 0.35/0.85 spring，GPU 只移位，切换才顺。
        .asymmetric(
            insertion: .move(edge: slideEdge),
            removal: .move(edge: slideEdge == .trailing ? .leading : .trailing)
        )
    }

    private func tabIndex(_ tab: AppState.DockTab) -> Int {
        switch tab { case .home: 0; case .mail: 1; case .ai: 2; case .my: 3 }
    }

    private func selectTab(_ tab: AppState.DockTab) {
        let old = tabIndex(app.dockTab), new = tabIndex(tab)
        if new != old { slideEdge = new > old ? .trailing : .leading }
        switch tab {
        case .home: app.selectedMessage = nil
        case .mail:
            app.selectedMailbox = .unified
            app.selectedMessage = nil
            compactColumn = .content
        case .ai, .my: break
        }
        app.dockTab = tab
    }
}

/// 角标数量单独放一个小 View：@Query 全量邮件只会让这个空 View 重算，
/// 同步、标已读时不会再牵连 RootView 的 body（dock、内容切换动画）。
private struct BadgeUpdater: View {
    @Query private var allMessages: [MailMessage]
    @AppStorage(Prefs.badgeSource) private var badgeSource = "inbox"
    @AppStorage(Prefs.vipList) private var vipRaw = ""

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: badgeCount, initial: true) { _, n in
                UNUserNotificationCenter.current().setBadgeCount(n)
            }
    }

    private var badgeCount: Int {
        _ = vipRaw
        switch badgeSource {
        case "none": return 0
        case "all": return allMessages.filter { !$0.isRead && !["junk", "trash", "sent", "drafts"].contains($0.folder?.role ?? "") }.count
        case "vip": return allMessages.filter { !$0.isRead && SmartFilter.matches("vip", $0) }.count
        default: return allMessages.filter { !$0.isRead && $0.folder?.role == "inbox" }.count
        }
    }
}
