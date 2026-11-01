import SwiftUI

/// 底部 Dock：稳定磨砂底板 + 单颗跟手的 Liquid Glass 选中滑块。
///
/// 结构约定：
/// 1. 底板只使用 regularMaterial，不再对整条 Dock 叠加 glassEffect，避免页面内容被重复折射。
/// 2. 只有选中滑块使用 glassEffect，且不再叠加高不透明度实体底色。
/// 3. 图标和文字独立置于最上层，避免玻璃层覆盖内容。
/// 4. 拖动状态留在本 View 内，不让 RootView 随手势每帧重算。
/// 5. 保留单一 DragGesture：点按和拖动均可切换栏目。
struct DockBar: View {
    @Environment(AppState.self) private var app
    /// 松手 / 点按落在某一栏时调用
    let onSelect: (AppState.DockTab) -> Void

    private static let tabs: [AppState.DockTab] = [.home, .mail, .ai, .my]

    private let inset: CGFloat = 2
    private let itemHeight: CGFloat = 56
    /// 按住时滑块在宽、高上各长出来多少
    private let growW: CGFloat = 18
    private let growH: CGFloat = 8

    @State private var barWidth: CGFloat = 0
    /// 手指的连续位置：0...3，小数表示在两栏之间；nil = 没在按
    @State private var dragProgress: Double?
    @State private var pressed = false
    /// 系统打断手势时 onEnded 不一定会走，靠它兜底复位
    @GestureState private var touching = false

    private var tabWidth: CGFloat { max(1, (barWidth - inset * 2) / CGFloat(Self.tabs.count)) }
    private var selectedIndex: Int { Self.tabs.firstIndex(of: app.dockTab) ?? 0 }
    private var progress: Double { dragProgress ?? Double(selectedIndex) }
    private var highlightedIndex: Int { Int(progress.rounded()) }

    var body: some View {
        ZStack(alignment: .leading) {
            dockBackground

            slider
                .zIndex(1)

            labels
                .zIndex(2)
        }
        .frame(height: itemHeight + inset * 2)
        .contentShape(Capsule())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
        .gesture(dockGesture)
        .onChange(of: touching) { _, isTouching in
            // 手势被系统取消：松手逻辑没跑，这里把按住状态收回来
            if !isTouching, pressed { settle(to: nil) }
        }
        .sensoryFeedback(.selection, trigger: highlightedIndex)
    }

    /// 独立底板：保留系统材质的柔和模糊，但不参与 Liquid Glass 合成。
    /// 系统背景色轻微叠加，减少底下文字和图标透出，同时适配浅色 / 深色模式。
    private var dockBackground: some View {
        Capsule()
            .fill(.regularMaterial)
            .overlay {
                Capsule()
                    .fill(Color(uiColor: .systemBackground).opacity(0.38))
            }
            .overlay {
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(height: itemHeight + inset * 2)
            .accessibilityHidden(true)
    }

    // MARK: - 滑块

    private var slider: some View {
        let w = tabWidth + (pressed ? growW : 0)
        let h = itemHeight + (pressed ? growH : 0)
        // 滑块中心 = 第 progress 栏的中心；放大时向两侧均匀长出，中心不动
        let x = inset + CGFloat(progress) * tabWidth - (w - tabWidth) / 2

        return Capsule()
            .fill(.clear)
            .frame(width: w, height: h)
            .glassEffect(.regular, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.white.opacity(0.48), lineWidth: 0.8)
            }
            .offset(x: x)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - 图标 + 文字（独立显示在玻璃层上方）

    private var labels: some View {
        HStack(spacing: 0) {
            ForEach(0..<Self.tabs.count, id: \.self) { i in
                let tab = Self.tabs[i]
                let on = i == highlightedIndex

                VStack(spacing: 3) {
                    Image(systemName: Self.icon(tab))
                        .font(.title3)
                    Text(Self.title(tab))
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(on ? Color.accentColor : Color.primary.opacity(0.68))
                .scaleEffect(on ? 1.08 : 1)
                .frame(maxWidth: .infinity)
                .frame(height: itemHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.title(tab))
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
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.68)) {
                        pressed = true
                    }
                }
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
