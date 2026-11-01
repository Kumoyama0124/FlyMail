import SwiftUI
import SwiftData

struct AccountSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
    @State private var preset = ProviderPreset.preset("qq")
    @State private var email = ""
    @State private var name = ""
    @State private var password = ""
    @State private var imapHost = ""
    @State private var smtpHost = ""
    @State private var imapPort = 993
    @State private var smtpPort = 465
    @State private var smtpImplicitTLS = true
    @State private var working = false
    @State private var error: String?
    @State private var picked: ProviderPreset?
    @State private var step2 = false

    var body: some View {
        NavigationStack {
            ProviderPickerView(selected: $picked)
                .navigationTitle("选择邮箱服务商")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("下一步") { if let p = picked { preset = p; applyPreset(p); step2 = true } }.disabled(picked == nil)
                    }
                }
                .navigationDestination(isPresented: $step2) { form }
        }
    }

    private var form: some View {
            Form {
                Section {
                    HStack(spacing: 12) {
                        ProviderBadge(preset: preset, size: 40)
                        Text(preset.name).font(.headline)
                    }
                }
                Section {
                    TextField("邮箱地址", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        .onChange(of: email) { _, e in
                            let g = ProviderPreset.guess(email: e)
                            if g.id != "custom", g.id != preset.id, preset.id == "custom" || ProviderPreset.guess(email: e).id != "custom" { preset = g; applyPreset(g) }
                        }
                    TextField("显示名称（可选）", text: $name)
                    SecureField("密码 / 授权码", text: $password)
                } footer: { Text(preset.passwordHint) }

                if let kind = preset.oauth {
                    Section {
                        Button {
                            Task { await addOAuth(kind) }
                        } label: { Label(kind == .oauthGoogle ? "使用 Google 登录" : "使用 Microsoft 登录", systemImage: "person.badge.key") }
                    }
                }
                Section("服务器") {
                    TextField("IMAP 服务器", text: $imapHost).textInputAutocapitalization(.never)
                    Stepper("IMAP 端口 \(imapPort)", value: $imapPort, in: 1...65535)
                    TextField("SMTP 服务器", text: $smtpHost).textInputAutocapitalization(.never)
                    Stepper("SMTP 端口 \(smtpPort)", value: $smtpPort, in: 1...65535)
                    Toggle("SMTP 使用 SSL（关闭则 STARTTLS）", isOn: $smtpImplicitTLS)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("添加账户")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("登录") { Task { await addPassword() } }.disabled(email.isEmpty || password.isEmpty || imapHost.isEmpty)
                    }
                }
            }
    }

    private func applyPreset(_ p: ProviderPreset) {
        guard p.id != "custom" else { return }
        imapHost = p.imapHost; imapPort = p.imapPort; smtpHost = p.smtpHost; smtpPort = p.smtpPort
        smtpImplicitTLS = p.smtpPort == 465
    }

    private func makeAccount(_ kind: AuthKind, email: String) -> Account {
        Account(displayName: name.isEmpty ? email : name, email: email, preset: preset, authKind: kind,
                imapHost: imapHost, imapPort: imapPort, smtpHost: smtpHost, smtpPort: smtpPort, smtpImplicitTLS: smtpImplicitTLS)
    }

    private func addPassword() async {
        working = true; error = nil; defer { working = false }
        let a = makeAccount(.password, email: email.trimmingCharacters(in: .whitespaces))
        KeychainStore.set(password, for: "\(a.id).password")
        await verifyAndSave(a)
    }

    private func addOAuth(_ kind: AuthKind) async {
        working = true; error = nil; defer { working = false }
        do {
            let t = try await OAuthService.shared.authorize(kind, loginHint: email)
            let addr = t.email ?? email
            guard !addr.isEmpty else { error = "无法获取邮箱地址，请先填写邮箱"; return }
            let a = makeAccount(kind, email: addr)
            CredentialProvider.save(t, accountID: a.id)
            await verifyAndSave(a)
        } catch { self.error = error.localizedDescription }
    }

    private func verifyAndSave(_ a: Account) async {
        do {
            let imap = try await AccountConfig(a).openIMAP()
            await imap.logout()
            context.insert(a)
            try context.save()
            let id = a.persistentModelID
            Task { _ = try? await MailSyncService(modelContainer: context.container).sync(accountID: id) }
            app.selectedMailbox = .unified
            dismiss()
        } catch {
            KeychainStore.deleteAll(accountID: a.id)
            self.error = "登录失败：\(error.localizedDescription)"
        }
    }
}
