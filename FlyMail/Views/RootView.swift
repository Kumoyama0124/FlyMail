import SwiftUI
import SwiftData
import UserNotifications

/// Dock 宽度偏好：拖动滑块时用它算手指落在哪一栏
private struct DockWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query private var accounts: [Account]
    @Query private var allMessages: [MailMessage]
    @AppStorage(Prefs.accent) private var accent = 0
    @AppStorage(Prefs.badgeSource) private var badgeSource = "inbox"
    @AppStorage(Prefs.vipList) private var vipRaw = ""
    @State private var columns: NavigationSplitViewVisibility = .all
    @Namespace private var dockNamespace
    @State private var dockWidth: CGFloat = 0
    @State private var isDragging = false
    /// 拖动中手指落在哪一栏（拖动时只动滑块，不切页，松手才切）
    @State private var dragTab: AppState.DockTab?
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
                    case .ai: AIPlaceholderView().transition(tabTransition)
                    case .my: MyView().transition(tabTransition)
                    }
                } else {
                    mailSplitView
                }
            }
            // 动画同节奏：pill 和内容用同一个 spring，pill 动、内容就跟着动，不脱节、不卡顿。
            // 之前 0.45/0.7 带过冲、内容还带缩放淡入，重列表（邮件）上最容易掉帧，看着就是“比之前好一点、但不顺”。
            // 改成 0.35/0.85：更快、过冲更小，内容只平移不缩放不淡入，GPU 不用重光栅，切换才顺。
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.dockTab)
            .tint(Prefs.palette[accent % Prefs.palette.count])
        }
        // dock 必须是真悬浮：用 overlay 贴在内容上面，内容铺满整个屏幕到底，dock 下面看到的就是页面本身的底色
        // （侧边栏/我的页是浅灰，首页/邮件列表是白），不再是一整块白色矩形。dock 再往下挪：overlay 底部只留 2pt，
        // 贴着小横条上面，比之前 8pt 更贴底。
        // 注意：dock 整块不要写在 body 里——body 本来就大，再加玻璃条 + 悬浮泡 + 手势，编译器会算不过来（Build #54 就是这么挂的）。
        // 拆成 dockOverlay / dockBar / floatingBubble 三个小表达式，各自单独算，就不超时了，效果不变。
        .overlay(alignment: .bottom) {
            // 底部 dock 栏：只在 iPhone（紧凑宽度）显示，iPad 有侧边栏就不需要，
            // 邮件详情页有自己的底部栏，dock 让位给它。
            if sizeClass == .compact, showDock {
                dockOverlay
            }
        }
        .onChange(of: badgeCount, initial: true) { _, n in
            UNUserNotificationCenter.current().setBadgeCount(n)
        }
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

    /// dock 整块（拆出来单独算，body 里只留一行引用，避免编译器超时）
    private var dockOverlay: some View {
        ZStack(alignment: .bottom) {
            floatingBubble
            dockBar
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.bottom, 2)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.dockTab)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: dragTab)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isDragging)
    }

    /// 长按/拖动悬浮出来的液态玻璃泡：按住 dock 不松手就弹出来，跟着手指落的那一栏走，
    /// 放大一圈、玻璃材质、带阴影，松手才落回 pill 里切过去——之前只有 pill 在条里放大，没有这个悬浮泡。
    private var floatingBubble: some View {
        Group {
            if isDragging, let dragTab {
                HStack(spacing: 6) {
                    Image(systemName: iconFor(dragTab)).font(.title3)
                    Text(titleFor(dragTab)).font(.caption.weight(.semibold))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background { Capsule().glassEffect(.regular, in: Capsule()) }
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .scaleEffect(1.15)
                .offset(x: floatingOffset(for: dragTab), y: -76)
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    /// dock 条子本身：液态玻璃 regular（不加白染色，详情页底部栏就是这么用的，真机上就是亮白玻璃），
    /// 顶部工具栏是系统自带的玻璃，不再叠加一层。
    private var dockBar: some View {
        HStack(spacing: 0) {
            dockButton("首页", systemImage: "house", selected: dockSelected(.home)) { selectTab(.home) }
            dockButton("邮件", systemImage: "tray", selected: dockSelected(.mail)) { selectTab(.mail) }
            dockButton("AI", systemImage: "sparkles", selected: dockSelected(.ai)) { selectTab(.ai) }
            dockButton("我的", systemImage: "person.crop.circle", selected: dockSelected(.my)) { selectTab(.my) }
        }
        .padding(2)
        .background { Capsule().glassEffect(.regular, in: Capsule()) }
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: DockWidthKey.self, value: geo.size.width)
            }
        }
        .onPreferenceChange(DockWidthKey.self) { dockWidth = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    isDragging = true
                    let w = dockWidth > 0 ? dockWidth : 320
                    let tabW = max(1, (w - 4) / 4)
                    let idx = min(3, max(0, Int((v.location.x - 2) / tabW)))
                    dragTab = tabForIndex(idx)
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        if let tab = dragTab { selectTab(tab) }
                        dragTab = nil
                        isDragging = false
                    }
                }
        )
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

    private func dockButton(_ title: String, systemImage: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.caption2.weight(.medium))
            }
            // 图二：未选中是黑色，不是灰色；选中是蓝色；选中时图标稍微放大一点，像别人那个视频里选中会弹一下
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .scaleEffect(selected ? 1.08 : 1.0)
            .frame(maxWidth: .infinity)
            // 定高 56：之前是图标 + 文字 + 上下 10pt padding，托盘图标本身比火花/房子/人头矮，
            // 邮件栏的 pill 就比其他栏矮一截，条子里上下留白多，看着就是“邮件页导航栏不一样、填充不满”。
            // 现在四个按钮都定高 56，pill 高度一样，条子里填满，不再因图标高矮而变。
            .frame(height: 56)
            // 滑块：灰色液态玻璃 pill，常驻在选中栏下面，填满整个按钮区，
            // 点按切栏、手指拖动时都用 matchedGeometryEffect 弹过去；
            // “我的”和其他栏目一样，拖动滑到它上面时滑块跟过去，松手就切到“我的”页。
            // 液态放大：手指按住在条上滑动时（isDragging），pill 横向拉长、纵向变高，像一滴液体被拉开，
            // 松手就用 spring 弹回正常大小。
            .background {
                if selected {
                    Capsule()
                        .glassEffect(.regular.tint(Color(.systemGray5)), in: Capsule())
                        .matchedGeometryEffect(id: "dockPill", in: dockNamespace)
                        .scaleEffect(isDragging ? CGSize(width: 1.18, height: 1.3) : CGSize(width: 1, height: 1))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var tabTransition: AnyTransition {
        // 内容只平移，不缩放不淡入：缩放 + 淡入要重光栅整页列表，邮件这种重列表最容易掉帧，
        // 看着就是“点按完整、拖动不顺”。纯平移 + 0.35/0.85 spring，GPU 只移位，切换才顺。
        .asymmetric(
            insertion: .move(edge: slideEdge),
            removal: .move(edge: slideEdge == .trailing ? .leading : .trailing)
        )
    }

    private func iconFor(_ tab: AppState.DockTab) -> String {
        switch tab { case .home: "house"; case .mail: "tray"; case .ai: "sparkles"; case .my: "person.crop.circle" }
    }

    private func titleFor(_ tab: AppState.DockTab) -> String {
        switch tab { case .home: "首页"; case .mail: "邮件"; case .ai: "AI"; case .my: "我的" }
    }

    /// 悬浮玻璃泡的横向偏移：对准手指落的那一栏的中心（dock 中心为 0，向左为负、向右为正）
    private func floatingOffset(for tab: AppState.DockTab) -> CGFloat {
        let w = dockWidth > 0 ? dockWidth : 320
        let tabW = max(1, (w - 4) / 4)
        return (CGFloat(tabIndex(tab)) - 1.5) * tabW
    }

    private func tabIndex(_ tab: AppState.DockTab) -> Int {
        switch tab { case .home: 0; case .mail: 1; case .ai: 2; case .my: 3 }
    }

    private func tabForIndex(_ idx: Int) -> AppState.DockTab {
        switch idx { case 0: .home; case 1: .mail; case 2: .ai; default: .my }
    }

    private func dockSelected(_ tab: AppState.DockTab) -> Bool {
        if isDragging, let dragTab { return dragTab == tab }
        return app.dockTab == tab
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
