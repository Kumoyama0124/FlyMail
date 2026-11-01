import Foundation

enum MIMEBuilder {
    static func build(from: String, fromName: String, to: [String], cc: [String], subject: String,
                      body: String, inReplyTo: String?, attachments: [AttachmentData], messageID: String? = nil) -> Data {
        let boundary = "FlyMail-\(UUID().uuidString)"
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        let domain = from.split(separator: "@").last.map(String.init) ?? "flymail.local"
        var h = [
            "From: \(encodeWord(fromName)) <\(from)>",
            "To: \(to.joined(separator: ", "))",
            "Subject: \(encodeWord(subject))",
            "Date: \(df.string(from: .now))",
            "Message-ID: \(messageID ?? "<\(UUID().uuidString)@\(domain)>")",
            "MIME-Version: 1.0",
        ]
        if !cc.isEmpty { h.append("Cc: \(cc.joined(separator: ", "))") }
        if let r = inReplyTo, !r.isEmpty { h.append("In-Reply-To: \(r)"); h.append("References: \(r)") }

        let textPart = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            + wrap(Data(body.utf8).base64EncodedString())
        var out: String
        if attachments.isEmpty {
            out = h.joined(separator: "\r\n") + "\r\n" + textPart
        } else {
            h.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            out = h.joined(separator: "\r\n") + "\r\n\r\n--\(boundary)\r\n" + textPart + "\r\n"
            for a in attachments {
                let name = encodeWord(a.filename)
                out += "--\(boundary)\r\nContent-Type: \(a.mimeType); name=\"\(name)\"\r\n"
                    + "Content-Disposition: attachment; filename=\"\(name)\"\r\n"
                    + "Content-Transfer-Encoding: base64\r\n\r\n" + wrap(a.data.base64EncodedString()) + "\r\n"
            }
            out += "--\(boundary)--\r\n"
        }
        return Data(out.utf8)
    }

    static func encodeWord(_ s: String) -> String {
        s.allSatisfy({ $0.isASCII }) ? s : "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }

    private static func wrap(_ s: String) -> String {
        var out = ""; var i = s.startIndex
        while i < s.endIndex {
            let e = s.index(i, offsetBy: 76, limitedBy: s.endIndex) ?? s.endIndex
            out += s[i..<e] + "\r\n"; i = e
        }
        return out
    }
}
