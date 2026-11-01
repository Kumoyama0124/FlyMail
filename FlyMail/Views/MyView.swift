import SwiftUI
import SwiftData
import PhotosUI

/// “我的”个人中心：样式参照 iOS 设置里的 Apple 账户页 + 常见 App 的“我的”页 ——
/// 顶部一张个人卡片（头像可换、昵称和签名可直接改），下面是分组列表入口。
struct MyView: View {
    @Environment(AppState.self) private var app
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query private var allMessages: [MailMessage]
    @AppStorage(Prefs.myNickname) private var nickname = ""
    @AppStorage(Prefs.mySignature) private var signature = ""
    @AppStorage(Prefs.myEmail) private var myEmail = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var avatarImage: UIImage?
    @State private var cropImage: UIImage?
    @State private var showingCrop = false
    @State private var showingSettings = false
    @State private var showingBackup = false

    private var avatarURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyAvatar.png")
    }

    private var unreadCount: Int {
        allMessages.filter { !$0.isRead && $0.folder?.role == "inbox" }.count
    }

    var body: some View {
        NavigationStack {
            List {
                // 个人卡片：头像 + 昵称 + 签名 + 邮箱，一眼就是你
                Section {
                    HStack(spacing: 16) {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Group {
                                if let avatarImage {
                                    Image(uiImage: avatarImage).resizable().scaledToFill()
                                } else {
                                    ZStack {
                                        Circle().fill(Color.accentColor.opacity(0.15))
                                        Text(String((nickname.isEmpty ? "我" : nickname).prefix(1)))
                                            .font(.largeTitle.weight(.semibold)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(width: 72, height: 72).clipShape(Circle())
                            .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("昵称", text: $nickname)
                                .font(.title3.weight(.semibold))
                            TextField("个性签名，写一句你想说的话", text: $signature)
                                .font(.subheadline).foregroundStyle(.secondary)
                            // 首要邮箱：不是锁死的，点开可以在账户间更换；
                            // 没账户时直接填一个邮箱地址也行
                            if accounts.isEmpty {
                                TextField("邮箱", text: $myEmail)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                            } else {
                                Menu {
                                    ForEach(accounts) { a in
                                        Button(a.email) { myEmail = a.email }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(myEmail.isEmpty ? (accounts.first?.email ?? "") : myEmail)
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Text("\(accounts.count) 个账户 · \(unreadCount) 封未读")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section {
                    NavigationLink { AccountsView() } label: {
                        LabeledContent { Text("\(accounts.count) 个") } label: {
                            Label("账户", systemImage: "person.2")
                        }
                    }
                    .foregroundStyle(.primary)
                    Button { showingSettings = true } label: {
                        HStack {
                            Label("设置", systemImage: "gearshape")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.primary)
                    .buttonStyle(.plain)
                    Button { showingBackup = true } label: {
                        HStack {
                            Label("备份与恢复", systemImage: "externaldrive")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.primary)
                    .buttonStyle(.plain)
                }
                // 帮助与反馈：独立一个模块区，不用模块名称；点进去是二级页，里面就是关于
                Section {
                    NavigationLink { HelpFeedbackView() } label: {
                        Label("帮助与反馈", systemImage: "questionmark.circle")
                    }
                    .foregroundStyle(.primary)
                }
                // dock 是悬浮盖在内容上面的，底部留 100pt 透明留白，最后一行才能滑到 dock 上面完整露出来，不被 dock 盖住
                Section {
                    Color.clear.frame(height: 100)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            .navigationTitle("我的")
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $showingBackup) { BackupRestoreSheetView() }
            // 裁切页：不管选的是 1:1 还是长方形，都弹出来，用户自己拖动、双指缩放，裁成想要的显示效果再保存，
            // 不直接把原图传上去。选完图先不写文件，裁完确认才写 MyAvatar.png。
            .sheet(isPresented: $showingCrop) {
                if let cropImage {
                    AvatarCropView(image: cropImage) {
                        showingCrop = false
                    } onDone: { cropped in
                        try? FileManager.default.createDirectory(at: avatarURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if let data = cropped.pngData() { try? data.write(to: avatarURL) }
                        avatarImage = cropped
                        showingCrop = false
                    }
                }
            }
            .onAppear { loadAvatar() }
            .onChange(of: pickerItem) { _, item in
                Task {
                    guard let data = try? await item?.loadTransferable(type: Data.self),
                          let img = UIImage(data: data) else { return }
                    pickerItem = nil
                    cropImage = img
                    showingCrop = true
                }
            }
        }
    }

    private func loadAvatar() {
        guard let data = try? Data(contentsOf: avatarURL) else { return }
        avatarImage = UIImage(data: data)
    }
}

/// 头像 1:1 裁切页：正方形裁切框，图片默认按“填满正方形”居中显示，
/// 手指拖动平移、双指缩放调整要显示的那一块，确认后才按框里的范围裁成正方形保存。
/// 裁切计算：先算原图按填满正方形时的基础缩放，再叠加用户的缩放和平移，
/// 反推框在原图里的正方形范围，用 UIGraphicsImageRenderer 按原图方向画出来（不直接裁 CGImage，避免方向错）。
struct AvatarCropView: View {
    let image: UIImage
    var onCancel: () -> Void
    var onDone: (UIImage) -> Void
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1
    @State private var lastOffset: CGSize = .zero
    @State private var displaySquare: CGFloat = 300

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let size = min(geo.size.width, geo.size.height) * 0.86
                let x0 = (geo.size.width - size) / 2
                let y0 = (geo.size.height - size) / 2 - 16
                // 关键：图片按"填满方框"的原始比例完整渲染（base 尺寸），不预先裁成方形——
                // 长方形图片溢出方框的部分被暗罩盖住，拖动就是真的在选区域，方框内也不会有黑块
                let base = baseSize(for: size)
                ZStack {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: base.width, height: base.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .position(x: geo.size.width / 2, y: y0 + size / 2)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture()
                                .onChanged { v in
                                    let s = scale
                                    // 图片填满正方形后的显示尺寸，缩放后超出正方形的那部分才能拖
                                    let baseW = baseSize(for: size).width * s
                                    let baseH = baseSize(for: size).height * s
                                    let maxX = max(0, (baseW - size) / 2)
                                    let maxY = max(0, (baseH - size) / 2)
                                    offset = CGSize(
                                        width: min(maxX, max(-maxX, lastOffset.width + v.translation.width)),
                                        height: min(maxY, max(-maxY, lastOffset.height + v.translation.height))
                                    )
                                }
                                .onEnded { _ in lastOffset = offset }
                            )
                            .simultaneousGesture(
                                MagnificationGesture()
                                    .onChanged { v in
                                        scale = min(3, max(1, lastScale * v))
                                    }
                                    .onEnded { _ in
                                        lastScale = scale
                                        // 缩放变小后，平移可能超出新范围，收回框内
                                        let s = scale
                                        let baseW = baseSize(for: size).width * s
                                        let baseH = baseSize(for: size).height * s
                                        let maxX = max(0, (baseW - size) / 2)
                                        let maxY = max(0, (baseH - size) / 2)
                                        offset = CGSize(width: min(maxX, max(-maxX, offset.width)), height: min(maxY, max(-maxY, offset.height)))
                                        lastOffset = offset
                                    }
                            )
                    // 四周暗罩：中间亮、四周暗，一眼看清裁切范围
                    Rectangle().fill(.black.opacity(0.55))
                        .frame(width: geo.size.width, height: max(0, y0))
                        .position(x: geo.size.width / 2, y: y0 / 2)
                    Rectangle().fill(.black.opacity(0.55))
                        .frame(width: geo.size.width, height: max(0, geo.size.height - (y0 + size)))
                        .position(x: geo.size.width / 2, y: y0 + size + (geo.size.height - (y0 + size)) / 2)
                    Rectangle().fill(.black.opacity(0.55))
                        .frame(width: max(0, x0), height: size)
                        .position(x: x0 / 2, y: y0 + size / 2)
                    Rectangle().fill(.black.opacity(0.55))
                        .frame(width: max(0, geo.size.width - (x0 + size)), height: size)
                        .position(x: x0 + size + (geo.size.width - (x0 + size)) / 2, y: y0 + size / 2)
                    // 1:1 白框 + 三分线 + 四角亮标
                    Rectangle().stroke(.white.opacity(0.95), lineWidth: 1.5)
                        .frame(width: size, height: size)
                        .position(x: geo.size.width / 2, y: y0 + size / 2)
                    VStack(spacing: 0) {
                        ForEach(1..<3) { i in
                            Rectangle().fill(.white.opacity(0.35)).frame(height: 0.5)
                                .position(x: geo.size.width / 2, y: y0 + size * CGFloat(i) / 3)
                            if i == 1 { Spacer(minLength: 0) }
                        }
                    }
                    .frame(width: geo.size.width, height: size)
                    .position(x: geo.size.width / 2, y: y0 + size / 2)
                    HStack(spacing: 0) {
                        ForEach(1..<3) { i in
                            Rectangle().fill(.white.opacity(0.35)).frame(width: 0.5)
                                .position(x: x0 + size * CGFloat(i) / 3, y: y0 + size / 2)
                            if i == 1 { Spacer(minLength: 0) }
                        }
                    }
                    .frame(width: size, height: size)
                    .position(x: geo.size.width / 2, y: y0 + size / 2)
                    CropCornerTicks()
                        .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: size, height: size)
                        .position(x: geo.size.width / 2, y: y0 + size / 2)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .onAppear { displaySquare = size }
                .onChange(of: geo.size) { _, _ in displaySquare = size }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 12) {
                    // 动过才出现：一键回到初始位置
                    if scale > 1.01 || offset.width != 0 || offset.height != 0 {
                        Button {
                            withAnimation(.snappy) {
                                scale = 1; lastScale = 1
                                offset = .zero; lastOffset = .zero
                            }
                        } label: {
                            Label("重置", systemImage: "arrow.counterclockwise")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 9)
                                .background(.white.opacity(0.16), in: Capsule())
                        }
                    }
                    Text("拖动调整位置 · 双指缩放 · 框内为最终头像")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(.bottom, 20)
                .animation(.snappy(duration: 0.2), value: scale)
            }
            .preferredColorScheme(.dark)
            .navigationTitle("裁切头像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        let size = 1024.0
                        onDone(croppedSquare(outputSize: size))
                    }
                }
            }
        }
    }

    /// 原图按填满正方形显示时的尺寸（点）：长边撑满，短边按比例
    private func baseSize(for square: CGFloat) -> CGSize {
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return CGSize(width: square, height: square) }
        let s = max(square / w, square / h)
        return CGSize(width: w * s, height: h * s)
    }

    /// 按当前缩放和平移，算出框在原图里的正方形范围，再画成输出尺寸的正方形图。
    /// 注意：平移量是按屏幕上实际正方形边长量的，所以反推必须用同一个 displaySquare，不能用固定 300。
    private func croppedSquare(outputSize: CGFloat) -> UIImage {
        let square = displaySquare
        let base = baseSize(for: square)
        let totalScale = (base.width / image.size.width) * scale
        // 框在原图里的边长（点）
        let cropLen = square / totalScale
        // 框中心在原图里的位置：原图中心 + （-平移量 / 总缩放）
        let cx = image.size.width / 2 + (-offset.width) / totalScale
        let cy = image.size.height / 2 + (-offset.height) / totalScale
        var origin = CGPoint(x: cx - cropLen / 2, y: cy - cropLen / 2)
        origin.x = min(max(0, origin.x), max(0, image.size.width - cropLen))
        origin.y = min(max(0, origin.y), max(0, image.size.height - cropLen))
        let drawScale = outputSize / cropLen
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: outputSize, height: outputSize))
        return renderer.image { _ in
            image.draw(in: CGRect(x: -origin.x * drawScale, y: -origin.y * drawScale,
                                  width: image.size.width * drawScale, height: image.size.height * drawScale))
        }
    }
}

/// 裁切框四角的亮色 L 形标记（系统照片裁切器同款）
struct CropCornerTicks: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let l: CGFloat = 18
        p.move(to: CGPoint(x: 0, y: l)); p.addLine(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: l, y: 0))
        p.move(to: CGPoint(x: rect.width - l, y: 0)); p.addLine(to: CGPoint(x: rect.width, y: 0)); p.addLine(to: CGPoint(x: rect.width, y: l))
        p.move(to: CGPoint(x: rect.width, y: rect.height - l)); p.addLine(to: CGPoint(x: rect.width, y: rect.height)); p.addLine(to: CGPoint(x: rect.width - l, y: rect.height))
        p.move(to: CGPoint(x: l, y: rect.height)); p.addLine(to: CGPoint(x: 0, y: rect.height)); p.addLine(to: CGPoint(x: 0, y: rect.height - l))
        return p
    }
}
