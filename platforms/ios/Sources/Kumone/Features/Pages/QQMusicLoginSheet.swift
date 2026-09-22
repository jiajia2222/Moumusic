import SwiftUI

struct QQMusicLoginSheet: View {
    @EnvironmentObject private var qqMusic: QQMusicSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var cookie = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?
#if os(iOS)
    @State private var showWebLogin = false
#endif

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("使用 QQ 音乐 Cookie 登录", systemImage: "person.badge.key.fill")
                            .font(.headline)
                        Text("登录只用于同步账号资料、推荐与歌单，不会替代 LX 音源。Cookie 仅保存在本机钥匙串。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
#if os(iOS)
                        Button { showWebLogin = true } label: {
                            Label("打开 QQ 音乐扫码登录", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(.borderedProminent)
#endif
                        TextEditor(text: $cookie)
                            .frame(minHeight: 110)
                            .font(.system(.footnote, design: .monospaced))
                            .privacySensitive()
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(.vertical, 6)
                }
                Section {
                    Button { signIn() } label: {
                        HStack {
                            Spacer()
                            if isSigningIn { ProgressView().controlSize(.small); Text("正在验证…") }
                            else { Text("验证并登录").fontWeight(.semibold) }
                            Spacer()
                        }
                    }
                    .disabled(isSigningIn || cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(minHeight: 44)
                }
                if qqMusic.isLoggedIn {
                    Section("当前状态") {
                        Label(qqMusic.profileName ?? "QQ 音乐已登录", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("QQ 音乐登录")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .alert("登录失败", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "请稍后重试") }
#if os(iOS)
            .sheet(isPresented: $showWebLogin) {
                ProviderWebLoginSheet(provider: .qqMusic) { value in
                    try await qqMusic.signIn(cookie: value)
                }
            }
#endif
        }
    }

    private func signIn() {
        isSigningIn = true
        Task {
            do {
                try await qqMusic.signIn(cookie: cookie)
                cookie = ""
                isSigningIn = false
                dismiss()
            } catch {
                isSigningIn = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
