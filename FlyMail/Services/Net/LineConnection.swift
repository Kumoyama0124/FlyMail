import Foundation

enum MailNetError: LocalizedError {
    case closed, timeout, protocolError(String)
    var errorDescription: String? {
        switch self {
        case .closed: return "连接已关闭"
        case .timeout: return "连接超时"
        case .protocolError(let s): return "协议错误：\(s)"
        }
    }
}

/// 基于 URLSessionStreamTask 的按行读写 TCP 连接，支持隐式 TLS 与 STARTTLS 升级。
final class LineConnection: @unchecked Sendable {
    private let task: URLSessionStreamTask
    private var buffer = Data()
    private let timeout: TimeInterval = 60

    init(host: String, port: Int, tls: Bool) {
        task = URLSession.shared.streamTask(withHostName: host, port: port)
        task.resume()
        if tls { task.startSecureConnection() }
    }

    func startTLS() { task.startSecureConnection() }
    func close() { task.closeWrite(); task.closeRead(); task.cancel() }

    func write(_ string: String) async throws { try await write(Data(string.utf8)) }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            task.write(data, timeout: timeout) { err in
                if let err { c.resume(throwing: err) } else { c.resume() }
            }
        }
    }

    private func fill(timeout t: TimeInterval? = nil) async throws {
        let chunk: Data = try await withCheckedThrowingContinuation { c in
            task.readData(ofMinLength: 1, maxLength: 64 * 1024, timeout: t ?? timeout) { data, eof, err in
                if let err { c.resume(throwing: err) }
                else if let data, !data.isEmpty { c.resume(returning: data) }
                else if eof { c.resume(throwing: MailNetError.closed) }
                else { c.resume(returning: Data()) }
            }
        }
        buffer.append(chunk)
    }

    /// 读一行（不含 CRLF）
    func readLine(timeout t: TimeInterval? = nil) async throws -> String {
        while true {
            if let r = buffer.range(of: Data([13, 10])) {
                let line = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return String(decoding: line, as: UTF8.self)
            }
            try await fill(timeout: t)
        }
    }

    /// 精确读取 n 字节（IMAP literal）
    func readBytes(_ n: Int) async throws -> Data {
        while buffer.count < n { try await fill() }
        let d = buffer.prefix(n)
        buffer.removeFirst(n)
        return Data(d)
    }
}
