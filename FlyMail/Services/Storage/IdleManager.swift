import Foundation
import SwiftData

/// 前台实时收信：每个账户一条 IMAP IDLE 连接（不支持则 60 秒轮询）
@MainActor
final class IdleManager {
    static let shared = IdleManager()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var clients: [UUID: IMAPClient] = [:]

    func start(container: ModelContainer) {
        let ctx = ModelContext(container)
        let accounts = (try? ctx.fetch(FetchDescriptor<Account>())) ?? []
        for a in accounts where tasks[a.id] == nil && a.isEnabled {
            let cfg = AccountConfig(a), pid = a.persistentModelID
            tasks[a.id] = Task { [weak self] in await self?.loop(cfg: cfg, accountPID: pid, container: container) }
        }
    }

    func restart(container: ModelContainer) { stop(); start(container: container) }

    func stop() {
        tasks.values.forEach { $0.cancel() }
        clients.values.forEach { $0.forceClose() }
        tasks.removeAll(); clients.removeAll()
    }

    private func loop(cfg: AccountConfig, accountPID: PersistentIdentifier, container: ModelContainer) async {
        let sync = MailSyncService(modelContainer: container)
        var backoff: UInt64 = 5
        while !Task.isCancelled {
            do {
                let imap = try await cfg.openIMAP()
                clients[cfg.id] = imap
                let interval = UserDefaults.standard.integer(forKey: Prefs.syncInterval)
                if interval != 0 {   // 定时 / 手动：不保持长连接
                    await imap.logout(); clients[cfg.id] = nil
                    guard interval > 0 else { return }
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: UInt64(interval) * 60_000_000_000)
                        _ = try? await sync.sync(accountID: accountPID, notify: true)
                        await sync.prefetchBodies(onWiFi: NetworkMonitor.shared.onWiFi)
                    }
                    return
                }
                let supportsIdle = try await imap.capabilities().contains("IDLE")
                if supportsIdle {
                    _ = try await imap.select("INBOX", readOnly: true)
                    backoff = 5
                    while !Task.isCancelled {
                        // 每 25 分钟重新 IDLE（RFC 2177 建议 29 分钟内）
                        if try await imap.idle(seconds: 25 * 60) {
                            _ = try? await sync.sync(accountID: accountPID, notify: true)
                            await sync.prefetchBodies(onWiFi: NetworkMonitor.shared.onWiFi)
                        }
                    }
                } else {
                    await imap.logout()
                    clients[cfg.id] = nil
                    while !Task.isCancelled {
                        _ = try? await sync.sync(accountID: accountPID, notify: true)
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    }
                }
            } catch {
                clients[cfg.id]?.forceClose(); clients[cfg.id] = nil
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 300)
            }
        }
    }
}

import Network

/// 当前网络是否为 Wi-Fi / 有线（用于“仅 Wi-Fi”下载策略）
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()
    private let monitor = NWPathMonitor()
    private(set) var onWiFi = false
    private init() {
        monitor.pathUpdateHandler = { [weak self] p in
            self?.onWiFi = p.status == .satisfied && !p.isExpensive && (p.usesInterfaceType(.wifi) || p.usesInterfaceType(.wiredEthernet))
        }
        monitor.start(queue: DispatchQueue(label: "flymail.net"))
    }
}
