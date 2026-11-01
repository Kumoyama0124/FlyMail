import SwiftUI

/// 悬浮液态玻璃 Dock。文字和图标始终绘制在滑块上层，避免玻璃效果把标签一起合成掉。
struct DockBar: View {
    @Environment(AppState.self) private var app
    let onSelect: (AppState.DockTab) -> Void

    private static let tabs: [AppState.DockTab] = [.home, .mail, .ai, .my]
    private let inset: CGFloat = 4
    private let itemHeight: CGFloat = 56

    @State private var barWidth: CGFloat = 0
    @State private var dragProgress: Double?
    @State private var pressed = false
    @GestureState private var touching = false

    private var tabWidth: CGFloat {
        max(1, (barWidth - inset * 2) / CGFloat(Self.tabs.count))
    }
    private var selectedIndex: Int {
        Self.tabs.firstIndex(of: app.dockTab) ?? 0
    }
    private var progress: Double {
        dragProgress ?? Double(selectedIndex)
    }
    private var highlightedIndex: Int {
        Int(progress.rounded())
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.regularMaterial)
                .overlay {
                    Capsule().fill(Color(uiColor: .systemBackground).opacity(0.30))
                }
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
                .zIndex(0)

            slider
                .zIndex(1)

            labels
                .zIndex(2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: itemHeight + inset * 2)
        .contentShape(Capsule())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
        .gesture(dockGesture)
        .onChange(of: touching) { _, isTouching in
            if !isTouching, pressed { settle(to: nil) }
        }
        .sensoryFeedback(.selection, trigger: highlightedIndex)
    }

    private var slider: some View {
        let width = max(1, tabWidth - 4 + (pressed ? 12 : 0))
        let height = itemHeight - 4 + (pressed ? 6 : 0)
        let x = inset + CGFloat(progress) * tabWidth - (width - (tabWidth - 4)) / 2 + 2

        return Capsule()
            .fill(Color(uiColor: .secondarySystemBackground).opacity(0.94))
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.72), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.04), radius: 4, y: 1)
            .frame(width: width, height: height)
            .offset(x: x)
            .allowsHitTesting(false)
    }

    private var labels: some View {
        HStack(spacing: 0) {
            ForEach(0..<Self.tabs.count, id: \.self) { index in
                let tab = Self.tabs[index]
                let selected = index == highlightedIndex
                VStack(spacing: 3) {
                    Image(systemName: Self.icon(tab))
                        .font(.system(size: 18, weight: .semibold))
                    Text(Self.title(tab))
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(selected ? Color.accentColor : Color.primary.opacity(0.76))
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

    private var dockGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                if !pressed {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.68)) {
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

    private func progressFor(x: CGFloat) -> Double {
        let value = Double((x - inset) / tabWidth) - 0.5
        return min(Double(Self.tabs.count - 1), max(0, value))
    }

    private func settle(to index: Int?) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.76)) {
            pressed = false
            dragProgress = nil
            if let index, Self.tabs.indices.contains(index) {
                onSelect(Self.tabs[index])
            }
        }
    }

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
