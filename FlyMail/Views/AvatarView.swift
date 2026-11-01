import SwiftUI

struct AvatarView: View {
    let from: String
    var size: CGFloat = 36
    var allowRemote = true
    @AppStorage(Prefs.remoteAvatars) private var remoteEnabled = true
    @State private var image: UIImage?

    private var email: String { MIMEParser.addresses(from).first?.lowercased() ?? "" }
    private var initials: String {
        let n = displayName(from).trimmingCharacters(in: .whitespaces)
        guard let c = n.first else { return "?" }
        return String(c).uppercased()
    }
    private var color: Color {
        let h = email.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return Prefs.palette[h % Prefs.palette.count]
    }

    var body: some View {
        ZStack {
            if let image {
                // 100% 铺满：不再 scaledToFit + 内边距留白，直接拉伸到整个头像框，
                // 再由外层 clipShape 裁成圆形，图标本身不被裁掉、也不留白边。
                Image(uiImage: image).resizable().interpolation(.high).frame(width: size, height: size).background(Color.white)
            } else {
                color.opacity(0.85)
                Text(initials).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.quaternary, lineWidth: 0.5))
        .task(id: email + "\(remoteEnabled && allowRemote)") {
            image = nil
            guard remoteEnabled, allowRemote, !email.isEmpty else { return }
            image = await AvatarService.shared.image(for: email, name: displayName(from))
        }
    }
}
