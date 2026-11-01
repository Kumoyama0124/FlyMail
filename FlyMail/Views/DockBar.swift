import SwiftUI

/// 底部 dock：一整条液态玻璃 + 一颗跟着手指走的玻璃滑块（Apple 标签栏那种“长按拖动”效果）。
///
/// 和旧实现的关键区别：
/// 1. 独立 View，拖动状态（pressed / dragProgress）只在这里，不会让 RootView 的 body
///    （含 @Query、整页内容切换）每一帧都重算——这是之前“不流畅”的最大原因。
/// 2. 滑块只有一颗、一直存在，位置是连续值 progress（0...3），手指在两栏之间它就在两栏之间；
///    旧版是每栏各建一个 pill + matchedGeometryEffect，换栏时视图被销毁重建，所以会“跳”。
/// 3. 全部玻璃放进同一个 GlassEffectContainer，系统会把它们当成一组一起渲染、一起形变。
/// 4. 放大用改 frame 尺寸（玻璃按真实尺寸重新渲染，边缘保持锐利），不用 scaleEffect 去拉伸已经渲染好的玻璃。
/// 5. 不再用 Button + 全条 DragGesture 抢手势：整条只有一个手势，点按 = 没动的拖动。
struct DockBar: View {
    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    /// 松手 / 点按落在某一栏时调用
    let onSelect: (AppState.DockTab) -> Void

    private static let tabs: [AppState.DockTab] = [.home, .mail, .ai, .my]

    private let inset: CGFloat = 2
    private let itemHeight: CGFloat = 56
    /// 按住时滑块在宽、高上各多长出来多少（像一滴被按扁、拉开的液体）
    private let growW: CGFloat = 18
    private let growH: CGFloat = 8

    @State private var barWidth: CGFloat = 0
    /// 手指的连续位置：0...3，小数表示在两栏之间；nil = 没在按
    @State private var dragProgress: Double?
    @State private var pressed = false
    /// 系统打断手势（来电、滚动抢手势）时 onEnded 不一定会走，靠它兜底复位
    @GestureState private var touching = false

    private var tabWidth: CGFloat { max(1, (barWidth - inset * 2) / CGFloat(Self.tabs.count)) }
    private var selectedIndex: Int { Self.tabs.firstIndex(of: app.dockTab) ?? 0 }
    private var progress: Double { dragProgress ?? Double(selectedIndex) }
    private var highlightedIndex: Int { Int(progress.rounded()) }

    var body: some View {
        ZStack(alignment: .leading) {
            // 条子本身：干净的白色胶囊 + 柔和投影 + 发丝描边，观感对齐系统标签栏
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: itemHeight + inset * 2)
                .background {
                    Capsule()
                        .fill(
                            colorScheme == .dark
                            ? Color(uiColor: .secondarySystemBackground)
                            : Color(uiColor: .systemBackground)
                        )
                        .overlay {
                            Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                        }
                }
                .shadow(color: .black.opacity(0.10), radius: 18, y: 6)
            slider
            labels
        }
        .contentShape(Capsule())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
        .gesture(dockGesture)
        // 选中项切换时滑块带弹簧滑到新位置，按住时轻微鼓起
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: highlightedIndex)
        .onChange(of: touching) { _, isTouching in
            // 手势被系统取消：松手逻辑没跑，这里把按住状态收回来
            if !isTouching, pressed { settle(to: nil) }
        }
        .sensoryFeedback(.selection, trigger: highlightedIndex)
    }

    // MARK: - 滑块

    private var slider: some View {
        let w = tabWidth + (pressed ? growW : 0)
        let h = itemHeight + (pressed ? growH : 0)
        // 滑块中心 = 第 progress 栏的中心；放大时向两侧均匀长出，中心不动
        let x = inset + CGFloat(highlightedIndex) * tabWidth - (w - tabWidth) / 2
        // 选中高亮：清晰的浅灰胶囊，边缘利落、和 dock 融为一体，
        // 不用 glassEffect——玻璃落在白色实底条上会渲染成一团模糊的灰雾。
        return Color.clear
            .frame(width: w, height: h)
            .background {
                Capsule()
                    .fill(Color.primary.opacity(0.07))
                    .overlay {
                        Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    }
            }
            .offset(x: x)
            .allowsHitTesting(false)
    }

    // MARK: - 图标 + 文字（只负责显示，触摸交给外层手势）

    private var labels: some View {
        HStack(spacing: 0) {
            ForEach(0..<Self.tabs.count, id: \.self) { i in
                let tab = Self.tabs[i]
                let on = i == highlightedIndex
                VStack(spacing: 3) {
                    Image(systemName: Self.icon(tab)).font(.title3)
                    Text(L10n.t(Self.title(tab))).font(.caption2.weight(.medium))
                }
                // 未选中黑色，选中强调色；选中栏图标稍微放大
                .foregroundStyle(on ? Color.accentColor : .primary)
                .scaleEffect(on ? 1.08 : 1)
                .frame(maxWidth: .infinity)
                .frame(height: itemHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.t(Self.title(tab)))
                .accessibilityAddTraits(tab == app.dockTab ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { onSelect(tab) }
            }
        }
        .padding(.horizontal, inset)
        .allowsHitTesting(false)
    }

    // MARK: - 手势

    private var dockGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                if !pressed {
                    // 按下：滑块“鼓”起来，带一点回弹
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.68)) { pressed = true }
                }
                // 跟手：用很短的 interactiveSpring，位置连续跟随又带一点液体的拖拽感；
                // 不要在这里用 0.35 的长 spring，会让滑块明显落后手指。
                withAnimation(.interactiveSpring(response: 0.16, dampingFraction: 0.86)) {
                    dragProgress = progressFor(x: value.location.x)
                }
            }
            .onEnded { value in
                settle(to: Int(progressFor(x: value.location.x).rounded()))
            }
    }

    /// 手指位置 -> 连续的栏位置（0...3）
    private func progressFor(x: CGFloat) -> Double {
        let p = Double((x - inset) / tabWidth) - 0.5
        return min(Double(Self.tabs.count - 1), max(0, p))
    }

    /// 松手：滑块收回正常大小，落到目标栏；index 为 nil 表示被系统打断，只复位不切栏
    private func settle(to index: Int?) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.76)) {
            pressed = false
            dragProgress = nil
            if let index { onSelect(Self.tabs[index]) }
        }
    }

    // MARK: - 文案

    private static func icon(_ tab: AppState.DockTab) -> String {
        switch tab {
        case .home: "house"
        case .mail: "tray"
        case .ai: "sparkles"
        case .my: "person.crop.circle"
        }
    }

    private static func title(_ tab: AppState.DockTab) -> String {
        switch tab {
        case .home: "首页"
        case .mail: "邮件"
        case .ai: "AI"
        case .my: "我的"
        }
    }
}
