import Foundation

enum SMTPAuth { case password(String), xoauth2(String) }

/// 极简 SMTP 客户端（RFC 5321），支持 465 隐式 TLS 与 587 STARTTLS，AUTH LOGIN / XOAUTH2。
struct SMTPClient {
    let host: String
    let port: Int
    let implicitTLS: Bool

    func send(from: String, recipients: [String], data: Data, user: String, auth: SMTPAuth) async throws {
        let c = LineConnection(host: host, port: port, tls: implicitTLS)
        defer { c.close() }
        try await expect(c, 220)
        try await c.write("EHLO flymail.local\r\n"); try await expect(c, 250)
        if !implicitTLS {
            try await c.write("STARTTLS\r\n"); try await expect(c, 220)
            c.startTLS()
            try await c.write("EHLO flymail.local\r\n"); try await expect(c, 250)
        }
        switch auth {
        case .password(let pw):
            try await c.write("AUTH LOGIN\r\n"); try await expect(c, 334)
            try await c.write(Data(user.utf8).base64EncodedString() + "\r\n"); try await expect(c, 334)
            try await c.write(Data(pw.utf8).base64EncodedString() + "\r\n"); try await expect(c, 235)
        case .xoauth2(let token):
            let raw = "user=\(user)\u{01}auth=Bearer \(token)\u{01}\u{01}"
            try await c.write("AUTH XOAUTH2 \(Data(raw.utf8).base64EncodedString())\r\n"); try await expect(c, 235)
        }
        try await c.write("MAIL FROM:<\(from)>\r\n"); try await expect(c, 250)
        for r in recipients {
            try await c.write("RCPT TO:<\(r)>\r\n"); try await expect(c, 250, alt: 251)
        }
        try await c.write("DATA\r\n"); try await expect(c, 354)
        // 点转义
        var text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n.", with: "\r\n..")
        if text.hasPrefix(".") { text = "." + text }
        try await c.write(text + "\r\n.\r\n"); try await expect(c, 250)
        try? await c.write("QUIT\r\n")
    }

    private func expect(_ c: LineConnection, _ code: Int, alt: Int? = nil) async throws {
        while true {
            let line = try await c.readLine()
            guard line.count >= 3, let got = Int(line.prefix(3)) else { throw MailNetError.protocolError(line) }
            let more = line.count > 3 && line[line.index(line.startIndex, offsetBy: 3)] == "-"
            if more { continue }
            guard got == code || got == alt else { throw MailNetError.protocolError(line) }
            return
        }
    }
}
