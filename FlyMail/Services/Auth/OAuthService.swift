import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var email: String?
}

/// OAuth2 授权码 + PKCE，直连 Google / Microsoft，无任何第三方中转。
@MainActor
final class OAuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthService()

    struct Provider {
        let authURL: String, tokenURL: String, clientID: String, scope: String, redirect: String, callbackScheme: String
    }

    nonisolated static func provider(_ kind: AuthKind) -> Provider {
        let info = Bundle.main.infoDictionary ?? [:]
        switch kind {
        case .oauthGoogle:
            let cid = info["FMGoogleClientID"] as? String ?? ""
            // Google iOS 客户端的回调 scheme 为反转的 client id
            let scheme = cid.split(separator: ".").reversed().joined(separator: ".")
            return Provider(authURL: "https://accounts.google.com/o/oauth2/v2/auth",
                            tokenURL: "https://oauth2.googleapis.com/token", clientID: cid,
                            scope: "https://mail.google.com/ openid email",
                            redirect: "\(scheme):/oauth2redirect", callbackScheme: scheme)
        default:
            let cid = info["FMMicrosoftClientID"] as? String ?? ""
            let scheme = "msauth.com.gymbull.flymail"
            return Provider(authURL: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
                            tokenURL: "https://login.microsoftonline.com/common/oauth2/v2.0/token", clientID: cid,
                            scope: "offline_access openid email https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send",
                            redirect: "\(scheme)://auth", callbackScheme: scheme)
        }
    }

    func authorize(_ kind: AuthKind, loginHint: String?) async throws -> OAuthTokens {
        let p = Self.provider(kind)
        guard !p.clientID.isEmpty, !p.clientID.hasPrefix("YOUR_") else {
            throw MailNetError.protocolError("未配置 OAuth Client ID，请参见 README")
        }
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(24)
        var c = URLComponents(string: p.authURL)!
        c.queryItems = [
            .init(name: "client_id", value: p.clientID), .init(name: "redirect_uri", value: p.redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: p.scope),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state), .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: kind == .oauthGoogle ? "consent" : "select_account"),
        ]
        if let h = loginHint, !h.isEmpty { c.queryItems?.append(.init(name: "login_hint", value: h)) }

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: p.callbackScheme) { url, err in
                if let url { cont.resume(returning: url) } else { cont.resume(throwing: err ?? MailNetError.closed) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = true
            s.start()
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw MailNetError.protocolError("OAuth 回调无效")
        }
        return try await Self.tokenRequest(p, params: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": p.redirect, "code_verifier": verifier,
        ], previousRefresh: nil)
    }

    nonisolated static func refresh(_ kind: AuthKind, tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let rt = tokens.refreshToken else { throw MailNetError.protocolError("缺少 refresh token，请重新登录") }
        var t = try await tokenRequest(provider(kind), params: ["grant_type": "refresh_token", "refresh_token": rt], previousRefresh: rt)
        t.email = t.email ?? tokens.email
        return t
    }

    nonisolated private static func tokenRequest(_ p: Provider, params: [String: String], previousRefresh: String?) async throws -> OAuthTokens {
        var req = URLRequest(url: URL(string: p.tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = params; all["client_id"] = p.clientID
        if p.tokenURL.contains("microsoft") { all["scope"] = p.scope }
        req.httpBody = all.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = json["access_token"] as? String else {
            throw MailNetError.protocolError(String(decoding: data, as: UTF8.self))
        }
        let exp = (json["expires_in"] as? Double) ?? 3600
        var email: String?
        if let idt = json["id_token"] as? String { email = jwtEmail(idt) }
        return OAuthTokens(accessToken: at, refreshToken: (json["refresh_token"] as? String) ?? previousRefresh,
                           expiresAt: .now.addingTimeInterval(exp - 60), email: email)
    }

    nonisolated private static func jwtEmail(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return (j["email"] as? String) ?? (j["preferred_username"] as? String)
    }

    nonisolated private static func randomString(_ n: Int) -> String {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b).base64URL
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// 根据账户类型给出可用的凭据（自动刷新 OAuth）
enum CredentialProvider {
    enum Cred { case password(String), token(String) }

    static func credential(accountID: UUID, kind: AuthKind) async throws -> Cred {
        switch kind {
        case .password:
            guard let pw = KeychainStore.get("\(accountID).password") else { throw MailNetError.protocolError("找不到密码，请重新设置账户") }
            return .password(pw)
        case .oauthGoogle, .oauthMicrosoft:
            guard let raw = KeychainStore.get("\(accountID).oauth"),
                  var t = try? JSONDecoder().decode(OAuthTokens.self, from: Data(raw.utf8)) else {
                throw MailNetError.protocolError("OAuth 令牌丢失，请重新登录")
            }
            if t.expiresAt < .now {
                t = try await OAuthService.refresh(kind, tokens: t)
                save(t, accountID: accountID)
            }
            return .token(t.accessToken)
        }
    }

    static func save(_ t: OAuthTokens, accountID: UUID) {
        if let d = try? JSONEncoder().encode(t) { KeychainStore.set(String(decoding: d, as: UTF8.self), for: "\(accountID).oauth") }
    }
}
