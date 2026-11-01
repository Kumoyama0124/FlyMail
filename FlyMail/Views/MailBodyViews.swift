import SwiftUI
import WebKit
import SafariServices

/// 手机友好的 HTML 正文：自适应高度、缩放适配、深色模式、只运行我们自己的排版脚本
struct MailHTMLView: UIViewRepresentable {
    let html: String
    /// false：拦截远程图片/样式/字体（防止发件人通过追踪像素得知你打开了邮件）
    var allowRemote: Bool = true
    @Binding var height: CGFloat
    @Environment(\.colorScheme) private var scheme

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "oxHeight")
        cfg.dataDetectorTypes = [.link, .phoneNumber, .address, .calendarEvent]
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        v.isOpaque = false
        v.backgroundColor = .clear
        v.scrollView.isScrollEnabled = false       // 外层 ScrollView 负责滚动
        v.scrollView.bounces = false
        v.scrollView.minimumZoomScale = 1
        v.scrollView.maximumZoomScale = 5
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {
        let key = "\(html.hashValue)-\(scheme == .dark)-\(allowRemote)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        v.loadHTMLString(Self.document(html, dark: scheme == .dark, allowRemote: allowRemote), baseURL: nil)
    }

    static func sanitize(_ html: String) -> String {
        html.replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<meta[^>]+(viewport|refresh|content-security-policy)[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"javascript:"#, with: "", options: .caseInsensitive)
            // 固定宽度表格 → 100%
            .replacingOccurrences(of: #"(<table[^>]*?)\swidth\s*=\s*["']?\d{3,4}(px)?["']?"#, with: "$1 width=\"100%\"", options: [.regularExpression, .caseInsensitive])
    }

    /// 邮件里是否有需要联网加载的内容（远程图片、CSS 背景图、背景属性）
    static func hasRemoteContent(_ html: String) -> Bool {
        let patterns = [#"<img[^>]+src\s*=\s*["']?\s*(https?:)?//"#,
                        #"url\(\s*["']?\s*(https?:)?//"#,
                        #"\sbackground\s*=\s*["']?\s*(https?:)?//"#]
        return patterns.contains { html.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    static func document(_ raw: String, dark: Bool, allowRemote: Bool = true) -> String {
        let nonce = UUID().uuidString
        // 默认放行远程内容；allowRemote == false 时只允许内嵌(data:)资源，脚本仍只认我们自己的 nonce
        let csp = allowRemote
            ? "default-src 'none'; img-src * data: blob:; style-src 'unsafe-inline' *; font-src * data:; media-src *; script-src 'nonce-\(nonce)'"
            : "default-src 'none'; img-src data: blob:; style-src 'unsafe-inline'; font-src data:; media-src 'none'; script-src 'nonce-\(nonce)'"
        let lower = raw.lowercased()
        // 有自己背景色的“设计型”邮件保持浅色，避免反色
        let designed = lower.contains("bgcolor") || lower.contains("background:") || lower.contains("background-color")
        let darkCSS = dark ? (designed
            ? "html{background:#1c1c1e} .ox-wrap{background:#fff;color:#000;border-radius:10px;padding:8px} :root{color-scheme:light}"
            : ":root{color-scheme:dark} body{color:#e5e5ea} a{color:#4da3ff} blockquote{border-color:#555}") : ":root{color-scheme:light}"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=5, user-scalable=yes">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <style>
        html,body{margin:0;padding:0;-webkit-text-size-adjust:100%}
        body{font:-apple-system-body;font-family:-apple-system,"PingFang SC",sans-serif;line-height:1.5;word-wrap:break-word;overflow-wrap:anywhere}
        .ox-wrap{padding:2px}
        img,video,iframe{max-width:100%!important;height:auto!important}
        table{max-width:100%!important}
        td,th{word-break:break-word}
        pre{white-space:pre-wrap}
        blockquote{margin:0 0 0 6px;padding-left:10px;border-left:3px solid #ccc}
        \(darkCSS)
        </style></head><body><div class="ox-wrap" id="ox">\(sanitize(raw))</div>
        <script nonce="\(nonce)">
        (function(){
          var box=document.getElementById('ox');
          function fit(){
            box.style.transform='';box.style.width='';
            var vw=document.documentElement.clientWidth, w=box.scrollWidth;
            if(w>vw+2){var s=vw/w;box.style.transformOrigin='0 0';box.style.transform='scale('+s+')';box.style.width=w+'px';}
            var r=box.getBoundingClientRect();
            window.webkit.messageHandlers.oxHeight.postMessage(Math.ceil(r.height)+8);
          }
          window.addEventListener('load',fit);
          if(window.ResizeObserver){new ResizeObserver(fit).observe(box);}
          Array.prototype.forEach.call(document.images,function(i){i.addEventListener('load',fit);});
          fit();
        })();
        </script></body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MailHTMLView
        var loadedKey = ""
        init(_ p: MailHTMLView) { parent = p }

        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            if let h = message.body as? Double ?? (message.body as? Int).map(Double.init), h > 0 {
                DispatchQueue.main.async { if abs(self.parent.height - h) > 1 { self.parent.height = h } }
            }
        }

        func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard a.navigationType == .linkActivated, let url = a.request.url else { decisionHandler(.allow); return }
            decisionHandler(.cancel)
            openExternal(url)
        }
    }
}

/// http(s) 用 SFSafariViewController 打开，其他（mailto/tel）交给系统
@MainActor
func openExternal(_ url: URL) {
    if ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
       let top = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.rootViewController {
        var vc = top
        while let p = vc.presentedViewController { vc = p }
        vc.present(SFSafariViewController(url: url), animated: true)
    } else {
        UIApplication.shared.open(url)
    }
}

/// 纯文本正文：自动换行、链接识别、引用折叠
struct PlainTextBody: View {
    let text: String
    @State private var showQuoted = false

    private var split: (String, String) {
        let lines = text.components(separatedBy: "\n")
        let markers = [#"^\s*>"#, #"^在.{2,80}写道[：:]\s*$"#, #"^On .{4,120} wrote:\s*$"#, #"^-{3,}\s*(Original Message|原始邮件|转发的邮件)"#,
                       #"^-{5,}\s*$"#, #"^(发件人|From)[：:]\s*.+"#]
        if let idx = lines.firstIndex(where: { l in markers.contains { l.range(of: $0, options: .regularExpression) != nil } }), idx > 0 {
            return (lines[..<idx].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                    lines[idx...].joined(separator: "\n"))
        }
        return (text, "")
    }

    var body: some View {
        let (main, quoted) = split
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.linkify(main)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !quoted.isEmpty {
                Button(showQuoted ? "隐藏引用内容" : "显示引用内容", systemImage: showQuoted ? "chevron.up" : "ellipsis.bubble") {
                    withAnimation { showQuoted.toggle() }
                }
                .font(.caption).buttonStyle(.bordered)
                if showQuoted {
                    Text(Self.linkify(quoted)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 3) }
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in openExternal(url); return .handled })
    }

    static func linkify(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.phoneNumber.rawValue) else { return a }
        let ns = s as NSString
        for m in det.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            guard let r = Range(m.range, in: s), let ar = Range(r, in: a) else { continue }
            if let url = m.url { a[ar].link = url }
            else if let p = m.phoneNumber, let u = URL(string: "tel:\(p.filter { $0.isNumber || $0 == "+" })") { a[ar].link = u }
        }
        return a
    }
}
